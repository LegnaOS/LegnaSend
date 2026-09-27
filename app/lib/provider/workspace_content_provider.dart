import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/workspace/workspace_content_store.dart';
import 'package:refena_flutter/refena_flutter.dart';

class WorkspaceContentSnapshot {
  final Map<String, WorkspaceContentState> entries;
  final bool failed;
  const WorkspaceContentSnapshot({this.entries = const {}, this.failed = false});
}

final workspaceContentProvider = NotifierProvider<WorkspaceContentNotifier, WorkspaceContentSnapshot>((ref) => WorkspaceContentNotifier());

class WorkspaceContentNotifier extends Notifier<WorkspaceContentSnapshot> {
  late final WorkspaceContentStore _store;
  StreamSubscription? _catalogSubscription, _serverSubscription;
  int? _lastListener;
  bool _disposed = false, _syncDirty = false;
  Future<void>? _syncing;
  final Map<String, Future<String>> _pending = {};

  int? _listener() => ref.read(serverProvider) == null ? null : ref.notifier(serverProvider).listenerGeneration;

  @override
  WorkspaceContentSnapshot init() {
    _store = WorkspaceContentStore(
      persistence: _PreferencesContentPersistence(ref.read(persistenceProvider)),
      onChanged: (entries, failed) {
        if (!_disposed) state = WorkspaceContentSnapshot(entries: entries, failed: failed);
      },
    );
    _catalogSubscription = ref.stream(workspaceCatalogProvider).listen((_) => _schedule());
    _serverSubscription = ref.stream(serverProvider).listen((_) {
      final listener = _listener();
      if (listener != _lastListener) {
        _lastListener = listener;
        _schedule();
      }
    });
    unawaited(Future<void>.microtask(_synchronize));
    return const WorkspaceContentSnapshot();
  }

  void _schedule() => unawaited(_synchronize());

  Future<void> _synchronize() {
    if (_disposed) return Future.value();
    _syncDirty = true;
    return _syncing ??= _drain().whenComplete(() => _syncing = null);
  }

  Future<void> _drain() async {
    await Future<void>.value();
    while (_syncDirty && !_disposed) {
      _syncDirty = false;
      try {
        await _store.synchronize(() => ref.read(workspaceCatalogProvider), _listener);
      } catch (_) {
        // Store publishes unknown / storage failure, never an optimistic revision.
      }
    }
  }

  Future<String> observe(String request, {required int expectedListener}) {
    if (_disposed || request.length > 128 * 1024) return Future.error(StateError('Content observation unavailable'));
    final key = '$expectedListener:${sha256.convert(utf8.encode(request))}';
    final existing = _pending[key];
    if (existing != null) return existing;
    // A slow persistence backend must not accumulate retry copies indefinitely.
    if (_pending.length >= 256) return Future.error(StateError('Content observation busy'));
    final operation = _store
        .handle(
          request: request,
          catalog: () => ref.read(workspaceCatalogProvider),
          listener: _listener,
          expectedListener: expectedListener,
        )
        .whenComplete(() {
          _pending.remove(key);
        });
    _pending[key] = operation;
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    _store.dispose();
    unawaited(_catalogSubscription?.cancel());
    unawaited(_serverSubscription?.cancel());
    super.dispose();
  }
}

class _PreferencesContentPersistence implements WorkspaceContentPersistence {
  final PersistenceService persistence;
  _PreferencesContentPersistence(this.persistence);
  @override
  Future<String?> read() async => persistence.getWorkspaceContent();
  @override
  Future<void> write(String value) => persistence.setWorkspaceContent(value);
}
