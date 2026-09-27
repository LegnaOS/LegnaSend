import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:refena_flutter/refena_flutter.dart';

final integrationApiPublicationProvider = NotifierProvider<IntegrationApiPublicationNotifier, IntegrationApiPublicationState>(
  (_) => IntegrationApiPublicationNotifier(),
);

class ApiRuntimeSnapshot {
  final String instanceId;
  final int revision;
  final int port;
  final int activeResponses;
  final int recordCount;
  final ApiPolicy policy;
  final Set<String> keyIds;
  ApiRuntimeSnapshot._(this.instanceId, this.revision, this.port, this.activeResponses, this.recordCount, this.policy, Set<String> keys)
    : keyIds = Set.unmodifiable(keys);
  factory ApiRuntimeSnapshot.parse(String raw) {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    final policy = ApiPolicy.fromJson({for (final key in ApiPolicy().toJson().keys) key: value[key]});
    return ApiRuntimeSnapshot._(
      value['instanceId'] as String,
      value['revision'] as int,
      value['port'] as int,
      value['activeResponses'] as int,
      value['recordCount'] as int,
      policy,
      (value['keys'] as List).map((key) => key['id'] as String).toSet(),
    );
  }
}

class IntegrationApiPublicationState {
  final ApiRuntimeSnapshot? runtime;
  final int? appliedGeneration;
  final bool busy;
  final bool failed;
  final DateTime? observedAt;
  const IntegrationApiPublicationState({this.runtime, this.appliedGeneration, this.busy = false, this.failed = false, this.observedAt});
}

/// Saved intent never becomes an active label until the running server acknowledges it.
class IntegrationApiPublicationNotifier extends Notifier<IntegrationApiPublicationState> {
  StreamSubscription? _settingsSubscription;
  StreamSubscription? _serverSubscription;
  Future<void>? _pending;
  bool _dirty = false;
  bool _refresh = false;
  bool _disposed = false;
  int _revision = 0;
  int? _serverGeneration;
  @override
  IntegrationApiPublicationState init() {
    _settingsSubscription = ref.stream(integrationApiSettingsProvider).listen((_) => unawaited(synchronize()));
    _serverSubscription = ref.stream(serverProvider).listen((_) {
      if (ref.notifier(serverProvider).generation != _serverGeneration || ref.read(serverProvider) == null) unawaited(synchronize());
    });
    unawaited(Future<void>.microtask(synchronize));
    return const IntegrationApiPublicationState();
  }

  Future<void> synchronize({bool refresh = false}) {
    if (_disposed) return Future.value();
    _dirty = true;
    _refresh |= refresh;
    return _pending ??= _drain().whenComplete(() => _pending = null);
  }

  Future<void> _drain() async {
    await Future<void>.value();
    while (_dirty && !_disposed) {
      _dirty = false;
      final force = _refresh;
      _refresh = false;
      final server = ref.notifier(serverProvider);
      final generation = server.generation;
      if (generation != _serverGeneration || ref.read(serverProvider) == null) {
        _serverGeneration = generation;
        state = const IntegrationApiPublicationState();
      }
      if (ref.read(serverProvider) == null) continue;
      final source = ref.read(integrationApiSettingsProvider);
      if (!source.initialized || source.corrupt) continue;
      if (source.generation == state.appliedGeneration && !force) continue;
      final previous = state;
      state = IntegrationApiPublicationState(
        runtime: previous.runtime,
        appliedGeneration: previous.appliedGeneration,
        busy: true,
        observedAt: previous.observedAt,
      );
      try {
        if (previous.runtime == null) {
          // A hot-restarted host may reconnect to an already-configured native listener.
          final before = ApiRuntimeSnapshot.parse(await server.integrationApiControl(expectedGeneration: generation));
          if (before.revision > _revision) _revision = before.revision;
        }
        if (source.generation != previous.appliedGeneration) {
          final revision = ++_revision;
          final acknowledgement =
              jsonDecode(
                    await server.integrationApiControl(
                      expectedGeneration: generation,
                      configuration: ref.notifier(integrationApiSettingsProvider).configuration(revision),
                    ),
                  )
                  as Map<String, dynamic>;
          if (acknowledgement['revision'] != revision ||
              acknowledgement['enabled'] != source.policy.enabled ||
              acknowledgement['keys'] != source.keys.length) {
            throw StateError('Invalid API acknowledgement');
          }
        }
        final runtime = ApiRuntimeSnapshot.parse(await server.integrationApiControl(expectedGeneration: generation));
        if (_disposed) return;
        if (server.generation != generation || ref.read(serverProvider) == null) {
          _dirty = true;
          continue;
        }
        if (runtime.port != ref.read(serverProvider)!.port || runtime.revision != _revision) throw StateError('Stale API snapshot');
        state = IntegrationApiPublicationState(runtime: runtime, appliedGeneration: source.generation, observedAt: DateTime.now());
      } catch (_) {
        if (_disposed) return;
        if (server.generation != generation || ref.read(serverProvider) == null) {
          _dirty = true;
          continue;
        }
        // The previous policy may still be live. Never replace it with saved intent.
        state = IntegrationApiPublicationState(
          runtime: previous.runtime,
          appliedGeneration: previous.appliedGeneration,
          failed: true,
          observedAt: previous.observedAt,
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_settingsSubscription?.cancel());
    unawaited(_serverSubscription?.cancel());
    super.dispose();
  }
}
