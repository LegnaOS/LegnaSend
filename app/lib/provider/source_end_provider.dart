import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:refena_flutter/refena_flutter.dart';

final sourceEndRequiredProvider = Provider<bool>((ref) => false);
final sourceEndStoreProvider = Provider<SourceEndStore?>((ref) => null);
final sourceEndProvider = NotifierProvider<SourceEndNotifier, List<Map<String, Object?>>>((ref) => SourceEndNotifier());

class SourceEndNotifier extends Notifier<List<Map<String, Object?>>> {
  SourceEndStore? get _store => ref.read(sourceEndStoreProvider);
  Timer? _timer;
  bool _closed = false, _ready = false;
  bool capacityLimited = false;
  final _running = <String>{}, _peers = <String>{};
  final _activeTasks = <int>{};
  StreamSubscription? _discovery;
  @override
  List<Map<String, Object?>> init() {
    return const [];
  }

  bool get available => _store != null;
  bool get requiresIntent => available || ref.read(sourceEndRequiredProvider);
  bool get storageHealthy => _store?.usable ?? !requiresIntent;

  // A restored task may already own a remote cleanup grant. A new task created
  // while bootstrap has no store never opted in and must remain cancelable.
  // A present but poisoned store is deliberately NOT treated as absent.
  bool requiresIntentFor(SendJob? job) => available || (ref.read(sourceEndRequiredProvider) && job?.restored == true);
  bool keyEndedForJob(SendJob? job, String peer, String key) => requiresIntentFor(job) && keyEnded(peer, key);
  Future<void> initialize() async {
    await _store?.initialize();
    if (_closed) return;
    if (_store != null) _discovery ??= ref.stream(nearbyDevicesProvider).listen((_) => wake());
    _ready = true;
    _refresh();
    wake();
  }

  void _refresh() {
    if (!_closed) state = List.unmodifiable(_store?.notices() ?? const []);
  }

  Future<bool> track({
    required SendJob? job,
    required String jobId,
    required Device peer,
    required String resumeKey,
    required String name,
    required String attemptId,
    required LocalSendRoute? route,
  }) async {
    final store = _store;
    if (store == null) return false;
    final enabled = await store.track(
      jobId: jobId,
      peer: peer.fingerprint,
      resumeKey: resumeKey,
      peerLabel: peer.alias,
      name: name,
      attemptId: attemptId,
      route: route?.toJson(),
      channel: job?.selectedChannel?.toJson(),
    );
    if (!enabled) capacityLimited = true;
    _refresh();
    return enabled;
  }

  Future<void> grant({
    required String peer,
    required String resumeKey,
    required String jobId,
    required String attemptId,
    required SourceEndGrant value,
  }) async {
    final store = _store;
    if (store == null) throw const SourceEndStorageException('unavailable');
    try {
      await store.recordGrant(peer: peer, resumeKey: resumeKey, jobId: jobId, attemptId: attemptId, grant: value);
      wake();
    } finally {
      _refresh();
    }
  }

  Future<void> unsupported(String peer, String key, String attempt) async {
    await _store?.unsupported(peer, key, attempt);
    _refresh();
  }

  Future<void> completed(String peer, String key) async {
    await _store?.completed(peer, key);
    _refresh();
  }

  Future<void> endJob(String jobId) async {
    if (_store == null && requiresIntent) throw const SourceEndStorageException('unavailable');
    try {
      await _store?.requestEnd(jobId);
      wake();
    } finally {
      _refresh();
    }
  }

  Future<void> sourceChanged(String job, String peer, String key) async {
    await _store?.requestEnd(job, onlyKey: SourceEndStore.key(peer, key));
    _refresh();
    wake();
  }

  Future<void> detached(String jobId) async {
    await _store?.detachOwner(jobId);
    _refresh();
    wake();
  }

  bool keyEnded(String peer, String key) {
    if (_store == null && requiresIntent) throw const SourceEndStorageException('unavailable');
    return _store?.ended(peer, key) ?? false;
  }

  Map<String, Object?> redactedNotices() {
    if (!storageHealthy) throw const SourceEndStorageException('unavailable');
    final rows = <Map<String, Object?>>[];
    var bytes = 64;
    for (final row in state) {
      final size = utf8.encode(jsonEncode(row)).length + 1;
      if (rows.length == 512 || bytes + size > 240 * 1024) break;
      rows.add(row);
      bytes += size;
    }
    return {'notices': rows, 'truncated': rows.length < state.length};
  }

  Future<Map<String, Object?>> retry(String id, String version, String requestId) async {
    final store = _store;
    if (store == null) throw const SourceEndStorageException('unavailable');
    try {
      final notice = await store.retry(id, version, requestId);
      wake();
      return {'notice': notice, 'accepted': true};
    } finally {
      _refresh();
    }
  }

  void wake() {
    if (_closed || !_ready || _store == null) return;
    _timer?.cancel();
    _timer = null;
    for (final notice in _store!.pending()) {
      if (_running.length >= 2) break;
      if (_running.contains(notice.id) || _peers.contains(notice.peer)) continue;
      _running.add(notice.id);
      _peers.add(notice.peer);
      unawaited(
        _send(notice)
            .whenComplete(() {
              _running.remove(notice.id);
              _peers.remove(notice.peer);
              _refresh();
              if (!_closed && _store!.hasScheduled) _timer ??= Timer(const Duration(seconds: 5), wake);
            })
            .catchError((Object _) {}),
      );
    }
    if (_store!.hasScheduled) _timer ??= Timer(const Duration(seconds: 5), wake);
  }

  Future<void> _send(SourceEndDispatch notice) async {
    final store = _store!;
    Future<void> mark(String value, {bool attempted = false, SourceEndResult? confirmation}) =>
        store.outcome(notice, value, attempted: attempted, confirmation: confirmation);
    try {
      if (notice.grant.expiresAtUnixMs <= store.now) {
        await mark('expired');
        return;
      }
      final ended = store.endedOwners(notice.peer, notice.resumeKey);
      final shared = ref
          .read(sendQueueProvider)
          .any(
            (job) =>
                job.target.fingerprint == notice.peer &&
                !ended.contains(job.id) &&
                job.resumeKeys.asMap().entries.any(
                  (e) => e.value == notice.resumeKey && !job.completedIndices.contains(e.key) && !job.skippedIndices.contains(e.key),
                ),
          );
      if (shared) {
        await mark('sharedSource');
        return;
      }
      final live = ref.read(nearbyDevicesProvider).devices[notice.peer];
      if (live == null || live.fingerprint != notice.peer) {
        await mark('waitingPeer');
        return;
      }
      final route = notice.route == null ? null : LocalSendRoute.fromJson(notice.route!);
      validateLocalSendRoute(route, ref.read(localIpProvider).addresses);
      final channel = notice.channel == null
          ? null
          : HttpChannel(host: notice.channel!['host'] as String, port: notice.channel!['port'] as int, https: notice.channel!['https'] as bool);
      final target = resolveSendTarget(live, live, channel);
      if (target.ip == null || route != null && !localSendRouteMatchesHost(route, target.ip)) {
        await mark('waitingPeer');
        return;
      }
      final task = ref
          .redux(parentIsolateProvider)
          .dispatchTakeResult(IsolateHttpSourceEndAction(target: target, localRoute: route, grant: notice.grant, requestId: notice.requestId));
      _activeTasks.add(task.taskId);
      SourceEndResult? result;
      try {
        final event = await task.events.where((e) => e is HttpSourceEndResultEvent).first.timeout(const Duration(seconds: 30));
        result = (event as HttpSourceEndResultEvent).result;
      } finally {
        _activeTasks.remove(task.taskId);
        if (!_closed) ref.redux(parentIsolateProvider).dispatch(IsolateHttpUploadCancelAction(taskId: task.taskId));
      }
      if (_closed) return;
      await mark(
        switch (result?.outcome) {
          SourceEndOutcome.cleared => 'removed',
          SourceEndOutcome.publishedPreserved => 'publishedPreserved',
          SourceEndOutcome.active || SourceEndOutcome.publicationPending => 'busy',
          SourceEndOutcome.authorizationRequired => 'authorizationRequired',
          SourceEndOutcome.superseded => 'superseded',
          SourceEndOutcome.unknownOrExpired => notice.grant.expiresAtUnixMs <= store.now ? 'expired' : 'unknown',
          SourceEndOutcome.retainedUnknown || null => 'unknown',
        },
        attempted: true,
        confirmation: result,
      );
    } on SelectedLocalRouteUnavailable {
      await mark('waitingPeer');
    } on SelectedChannelUnavailable {
      await mark('waitingPeer');
    } catch (_) {
      if (!_closed) {
        try {
          await mark('unknown');
        } catch (_) {
          /* Journal stays pending; no false acknowledgement. */
        }
      }
    }
  }

  @override
  void dispose() {
    final store = _store;
    _closed = true;
    _timer?.cancel();
    unawaited(_discovery?.cancel());
    for (final id in _activeTasks.toList()) {
      try {
        ref.redux(parentIsolateProvider).dispatch(IsolateHttpUploadCancelAction(taskId: id));
      } catch (_) {}
    }
    unawaited(store?.close().catchError((Object _) {}));
    super.dispose();
  }
}
