import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/provider/workspace_content_provider.dart';
import 'package:localsend_app/util/native/ios_workspace_grants.dart';
import 'package:refena_flutter/refena_flutter.dart';

final directoryPublicationProvider = NotifierProvider<DirectoryPublicationNotifier, DirectoryPublicationState>(
  (ref) => DirectoryPublicationNotifier(),
);

class DirectoryPublicationState {
  final Map<String, int> published;
  final bool busy;
  final bool failed;
  const DirectoryPublicationState({this.published = const {}, this.busy = false, this.failed = false});
}

/// Mirrors actual Rust acknowledgements, not just saved enable intentions.
/// Listeners coalesce changes and the server serializes updates with restarts.
class DirectoryPublicationNotifier extends Notifier<DirectoryPublicationState> {
  StreamSubscription? _catalogSubscription;
  StreamSubscription? _serverSubscription;
  StreamSubscription? _activitySubscription;
  int _releaseAfterSnapshot = -1;
  Set<String> _desiredGrants = {};
  Future<void>? _pending;
  bool _dirty = false;
  bool _disposed = false;
  int _revision = 0;
  int? _serverGeneration;
  String? _confirmed;
  WorkspaceGrantLease? _publishedLease;

  @override
  DirectoryPublicationState init() {
    ref.read(workspaceContentProvider);
    _catalogSubscription = ref.stream(workspaceCatalogProvider).listen((_) => unawaited(synchronize()));
    _serverSubscription = ref.stream(serverProvider).listen((_) {
      if (ref.notifier(serverProvider).generation != _serverGeneration || ref.read(serverProvider) == null) unawaited(synchronize());
    });
    _activitySubscription = ref.stream(webTransferActivityProvider).listen((_) {
      if (_publishedLease != null) unawaited(synchronize());
    });
    unawaited(Future<void>.microtask(synchronize));
    return const DirectoryPublicationState();
  }

  Future<void> synchronize() {
    if (_disposed) return Future.value();
    _dirty = true;
    return _pending ??= _drain().whenComplete(() => _pending = null);
  }

  Future<void> _trimLease({required bool stopped}) async {
    if (_publishedLease == null) {
      await _pruneGrants();
      return;
    }
    final activity = ref.notifier(webTransferActivityProvider);
    // A configuration acknowledgement only revokes new requests. Existing
    // publication workers can still use the directory after it or after stop.
    if (!activity.confirmedIdle || (!stopped && activity.snapshotRevision <= _releaseAfterSnapshot)) return;
    final grants = ref.read(iosWorkspaceGrantsProvider);
    _publishedLease = await grants.retainOnly(_publishedLease, stopped ? const [] : _desiredGrants);
    await _pruneGrants();
  }

  Future<void> _pruneGrants() async {
    final catalog = ref.read(workspaceCatalogProvider);
    if (!catalog.initialized) return;
    await ref.read(iosWorkspaceGrantsProvider).prune([
      for (final source in [...catalog.entries.map((entry) => entry.source), ...catalog.approvedSources.map((entry) => entry.source)])
        if (source.kind == WorkspaceSourceKind.appleBookmark && source.grantId != null) source.grantId!,
    ]);
  }

  Future<void> _drain() async {
    // Defer until _pending is assigned, including when no server is running.
    await Future<void>.value();
    while (_dirty && !_disposed) {
      _dirty = false;
      final server = ref.notifier(serverProvider);
      final generation = server.generation;
      if (generation != _serverGeneration || ref.read(serverProvider) == null) {
        _serverGeneration = generation;
        _confirmed = null;
        state = const DirectoryPublicationState();
      }
      if (ref.read(serverProvider) == null) {
        final stopped = await server.listenerStopBarrier;
        if (_disposed) return;
        if (ref.read(serverProvider) != null) {
          _dirty = true;
          continue;
        }
        if (stopped) {
          try {
            await _trimLease(stopped: true);
          } catch (_) {
            if (!_disposed) state = DirectoryPublicationState(published: state.published, failed: true);
          }
        }
        continue;
      }
      final catalog = ref.read(workspaceCatalogProvider);
      if (!catalog.initialized) continue;
      final workspaces = [
        for (final entry in catalog.publishable)
          {
            'id': entry.id,
            'name': entry.name,
            'slug': entry.slug,
            'root': entry.source.kind == WorkspaceSourceKind.androidTree ? '' : catalog.verifiedLocators[entry.id],
            if (entry.source.kind == WorkspaceSourceKind.androidTree) 'documentTree': catalog.verifiedLocators[entry.id],
            'generation': entry.generation,
            'visible': entry.visible,
            'allowUpload': entry.allowUpload,
            // Enabling uploads is the owner's standing consent for this workspace.
            // Access passwords, write grants and no-overwrite checks remain enforced.
            'uploadApproval': false,
            'passwordHash': entry.passwordHash,
          },
      ];
      final signature = jsonEncode(workspaces);
      if (signature == _confirmed) {
        try {
          await _trimLease(stopped: false);
        } catch (_) {
          if (!_disposed) state = DirectoryPublicationState(published: state.published, failed: true);
        }
        continue;
      }
      final revision = ++_revision;
      state = DirectoryPublicationState(published: state.published, busy: true);
      final grants = ref.read(iosWorkspaceGrantsProvider);
      final requestedGrants = catalog.publishable
          .where((entry) => entry.source.kind == WorkspaceSourceKind.appleBookmark)
          .map((entry) => entry.source.grantId!)
          .toSet();
      try {
        _publishedLease = await grants.acquire(requestedGrants, retaining: _publishedLease);
        for (final entry in catalog.publishable.where((entry) => entry.source.kind == WorkspaceSourceKind.appleBookmark)) {
          if (_publishedLease?.roots[entry.source.grantId] != catalog.verifiedLocators[entry.id]) {
            throw StateError('Workspace grant moved; validate again');
          }
        }
        if (_disposed || server.generation != generation || ref.read(serverProvider) == null) {
          _dirty = true;
          continue;
        }
        final result = await server.configureDirectoryWorkspaces(
          expectedGeneration: generation,
          config: jsonEncode({'revision': revision, 'enabled': true, 'workspaces': workspaces}),
        );
        if (_disposed) return;
        if (server.generation != generation || ref.read(serverProvider) == null) {
          _dirty = true;
          continue;
        }
        final acknowledgement = jsonDecode(result) as Map<String, dynamic>;
        if (acknowledgement['revision'] != revision) throw StateError('Stale directory acknowledgement');
        final published = {for (final row in acknowledgement['workspaces'] as List) row['id'] as String: row['generation'] as int};
        if (published.length != workspaces.length || workspaces.any((entry) => published[entry['id']] != entry['generation'])) {
          throw StateError('Incomplete directory acknowledgement');
        }
        state = DirectoryPublicationState(published: Map.unmodifiable(published));
        _desiredGrants = requestedGrants;
        final activities = ref.notifier(webTransferActivityProvider);
        _releaseAfterSnapshot = activities.snapshotRevision;
        if (_publishedLease != null) activities.requireFreshSnapshot();
        await _pruneGrants();
        _confirmed = signature;
      } catch (_) {
        if (_disposed) return;
        // If publication failed, previously confirmed routes may still exist.
        // The UI must display that fact instead of falsely reporting "closed".
        state = DirectoryPublicationState(published: state.published, failed: true);
      }
      // Failed/ambiguous publication keeps the one union lease. A later exact
      // acknowledgement trims it; failures never grow a list of retired leases.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Provider disposal is not a native listener-stop acknowledgement. Keep the
    // current native lease alive until process teardown rather than revoke an
    // unconfirmed still-serving root; normal stop drains it through the barrier.
    unawaited(_catalogSubscription?.cancel());
    unawaited(_serverSubscription?.cancel());
    unawaited(_activitySubscription?.cancel());
    super.dispose();
  }
}
