import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_app/util/send_retry.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_session_lookup.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

final sendQueueProvider = NotifierProvider<SendQueueNotifier, List<SendJob>>((ref) => SendQueueNotifier());

class SendQueueNotifier extends Notifier<List<SendJob>> {
  // Explicit cancellation stops the live attempt. Retain its last confirmed
  // outcomes in queue history so retry cannot duplicate completed destination files.
  final _canceledRemaining = <String, List<CrossFile>>{};

  List<CrossFile> _remaining(SendJob job) {
    final transfers = ref.read(fileTransferProvider);
    return remainingSendFiles(job, ref.read(sendProvider)[job.id], (fileId) => transfers.getStatus(sessionId: job.id, fileId: fileId));
  }

  late final SendQueue _queue = SendQueue(
    onChanged: _publish,
    abort: (job) {
      _canceledRemaining[job.id] = _remaining(job);
      return ref.notifier(sendProvider).cancelSessionAndWait(job.id);
    },
    execute: (job) async {
      await initializeRecovery();
      // A manual failed-file retry releases only its old terminal remote slot.
      // The release was captured synchronously before another local attempt can
      // replace that session. The new task still owns a separate queue ID.
      await _singleFileRetryReleases.remove(job.id);
      final saved = await _capture(job);
      if (_disposed || state.where((entry) => entry.id == job.id).firstOrNull?.status != SendJobStatus.running) return null;
      job = state.firstWhere((entry) => entry.id == job.id);
      // A storage failure is visible but ordinary in-memory sending stays usable.
      // Explicit restored continuation instead requires its saved immutable manifest.
      if (saved == null && _store != null) _issue('storage');
      final discovered = ref.read(nearbyDevicesProvider).allDevices[job.target.fingerprint];
      if (job.restored) {
        try {
          if (discovered == null) throw const SendRecoveryException('peerUnavailable');
          await _store!.validateRemaining(job);
        } catch (error) {
          final code = error is SendRecoveryException ? error.code : 'storage';
          final current = state.where((entry) => entry.id == job.id).firstOrNull;
          if (!_disposed && current != null) _queue.update(current.withRecovery(issue: code));
          throw StateError(code);
        }
      }
      if (_disposed || !_queue.isRunning(job.id) || state.where((entry) => entry.id == job.id).firstOrNull?.status != SendJobStatus.running) {
        return null;
      }
      final live = ref.read(nearbyDevicesProvider).allDevices[job.target.fingerprint];
      if (job.restored && live == null) {
        _queue.update(job.withRecovery(issue: 'peerUnavailable'));
        throw StateError('peerUnavailable');
      }
      _validateLocalRoute(job);
      final target = resolveSendTarget(job.target, live ?? discovered, job.selectedChannel);
      if (target.ip == null) throw StateError('No HTTP channel available for this device');
      if (findDeviceSendSession(ref.read(sendProvider).values, target, activeOnly: true) != null) {
        return SessionStatus.recipientBusy;
      }
      final indices = [
        for (var i = 0; i < job.files.length; i++)
          if (!job.restored || !job.completedIndices.contains(i) && !job.skippedIndices.contains(i)) i,
      ];
      _attemptIndices[job.id] = indices;
      _queue.update(job.withAttempt(indices));
      await ref
          .notifier(sendProvider)
          .startSession(
            target: target,
            files: [for (final index in indices) job.files[index]],
            background: true,
            requestedSessionId: job.id,
            retainSession: true,
            localRoute: job.localRoute,
            resumeKeys: saved != null && job.resumeKeysPersisted ? [for (final index in indices) job.resumeKeys[index]] : null,
          );
      await flushRecovery();
      final result = ref.read(sendProvider)[job.id]?.status;
      // Retain per-file outcomes until the history entry is removed. This keeps
      // rejected/skipped files out of the activity panel's completed byte totals.
      if (result != null && result != SessionStatus.finished) {
        // A new queue attempt will use a new session, not old per-file tokens.
        await ref.notifier(sendProvider).releaseRemoteSession(job.id);
      }
      return result;
    },
  );

  @override
  List<SendJob> init() => [];

  String enqueue(Device target, List<CrossFile> files) => _queue.enqueue(
    target,
    files,
    selectedChannel: ref.read(sendRouteProvider)[sendDeviceKey(target)],
    localRoute: ref.read(sendLocalRouteProvider)[sendDeviceKey(target)],
  );

  void _validateLocalRoute(SendJob job) {
    if (job.localRoute == null) return;
    try {
      validateLocalSendRoute(job.localRoute, ref.read(localIpProvider).addresses);
    } on SelectedLocalRouteUnavailable {
      final current = state.where((entry) => entry.id == job.id).firstOrNull;
      if (!_disposed && current != null && current.restored) {
        _queue.update(current.withRecovery(issue: 'selectedLocalRouteUnavailable'));
      }
      rethrow;
    }
  }

  final _singleFileRetries = <(String, String), (SendingFile, String)>{};
  final _singleFileRetryReleases = <String, Future<void>>{};

  @visibleForTesting
  int get pendingSingleFileRetryReleaseCount => _singleFileRetryReleases.length;

  /// Manual retries never reuse a terminal remote file token. In-isolate 422
  /// retries are separate and continue using their still-valid token.
  /// Publication into the queue is synchronous, protecting owned source paths
  /// from history removal until saveManifest has copied them to the new job.
  String? retryFile({required String sessionId, required SendingFile file}) {
    if (_disposed || _deleting.contains(sessionId) || _ending.contains(sessionId)) return null;
    final session = ref.read(sendProvider)[sessionId];
    if (session == null ||
        session.status != SessionStatus.finishedWithErrors ||
        session.sendingTasks?.isNotEmpty == true ||
        !identical(session.files[file.file.id], file) ||
        ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: file.file.id) != FileStatus.failed ||
        session.target.ip == null) {
      return null;
    }
    _singleFileRetries.removeWhere((key, value) => !state.any((job) => job.id == value.$2));
    final key = (sessionId, file.file.id);
    final existing = _singleFileRetries[key];
    if (existing != null && identical(existing.$1, file)) return existing.$2;
    final source = CrossFile(
      name: file.file.fileName,
      fileType: file.file.fileType,
      size: file.file.size,
      thumbnail: file.thumbnail,
      asset: file.asset,
      path: file.path,
      bytes: file.bytes,
      lastModified: file.file.metadata?.lastModified,
      lastAccessed: file.file.metadata?.lastAccessed,
    );
    final channel = HttpChannel(host: session.target.ip!, port: session.target.port, https: session.target.https);
    final job = state.where((entry) => entry.id == sessionId).firstOrNull;
    final id = _queue.enqueue(
      session.target,
      [source],
      selectedChannel: channel,
      localRoute: job == null ? session.localRoute : job.localRoute,
      resumeKeys: file.resumeKey == null
          ? null
          : [ref.notifier(sourceEndProvider).keyEndedForJob(job, session.target.fingerprint, file.resumeKey!) ? const Uuid().v4() : file.resumeKey!],
    );
    _singleFileRetries[key] = (file, id);
    _singleFileRetryReleases[id] = ref.notifier(sendProvider).releaseRemoteSession(sessionId);
    return id;
  }

  /// Explicit API routes never inherit the local UI route preference.
  String enqueueExplicit(Device target, List<CrossFile> files, HttpChannel channel, {LocalSendRoute? localRoute}) =>
      _queue.enqueue(target, files, selectedChannel: channel, localRoute: localRoute);

  /// Remote workspace reads must become owned durable sources before the stage is released.
  Future<String> enqueueOwned(
    Device target,
    List<CrossFile> files,
    HttpChannel channel, {
    bool Function()? isCurrent,
    LocalSendRoute? localRoute,
  }) async {
    await initializeRecovery();
    final store = _store;
    if (_disposed || store == null || isCurrent?.call() == false) throw StateError('Durable source storage unavailable');
    final job = SendJob(id: const Uuid().v4(), target: target, files: List.unmodifiable(files), selectedChannel: channel, localRoute: localRoute);
    // Disposal must retain the journal lease until copying or rollback drains.
    final capture = Completer<SendJob?>();
    _captures[job.id] = capture.future;
    SendJob? saved;
    var accepted = false;
    try {
      saved = await store.saveManifest(job, copyLocalSources: true);
      if (_disposed || isCurrent?.call() == false) throw StateError('Queue or owner changed');
      _persisted.add(job.id);
      final id = _queue.enqueuePrepared(saved);
      accepted = true;
      return id;
    } catch (_) {
      // A notification failure after actual admission must not erase live sources.
      if (_queue.jobs.any((entry) => entry.id == job.id)) {
        accepted = true;
        return job.id;
      }
      _persisted.remove(job.id);
      try {
        await store.remove(job.id);
      } catch (_) {
        if (!_disposed) _issue('storage');
      }
      rethrow;
    } finally {
      if (!accepted) unawaited(_captures.remove(job.id));
      capture.complete(accepted ? saved : null);
    }
  }

  Future<void> cancel(String id) async {
    final expected = state.where((job) => job.id == id).firstOrNull;
    if (_disposed || expected == null || expected.terminal || !_ending.add(id)) return;
    try {
      final sourceEnd = ref.notifier(sourceEndProvider);
      if (sourceEnd.requiresIntentFor(expected)) await sourceEnd.endJob(id);
      final current = state.where((job) => job.id == id).firstOrNull;
      if (_disposed || current == null || current.attemptRevision != expected.attemptRevision) return;
      _queue.cancel(id);
      if (state.where((job) => job.id == id).firstOrNull?.terminal == true) {
        unawaited(_singleFileRetryReleases.remove(id));
      }
    } finally {
      _ending.remove(id);
    }
  }

  void remove(String id) => unawaited(removeAndWait(id));

  Future<void> removeAndWait(String id) async {
    final expected = state.where((job) => job.id == id).firstOrNull;
    if (_disposed ||
        expected == null ||
        !expected.terminal ||
        expected.recoveryChecking ||
        _queue.isRunning(id) ||
        _ending.contains(id) ||
        !_deleting.add(id))
      return;
    // Reserve before awaiting intent persistence: retries must not adopt these
    // recovery keys while their source is concurrently being ended.
    try {
      final sourceEnd = ref.notifier(sourceEndProvider);
      if (sourceEnd.requiresIntentFor(expected)) await sourceEnd.endJob(id);
      final current = state.where((job) => job.id == id).firstOrNull;
      if (_disposed || current == null || !current.terminal || current.attemptRevision != expected.attemptRevision) return;
      if (_store != null) {
        await _removeRecovered(id);
      } else {
        _removeMemory(id);
        if (!state.any((job) => job.id == id)) await sourceEnd.detached(id);
      }
    } finally {
      _deleting.remove(id);
    }
  }

  void _removeMemory(String id) {
    final job = state.where((j) => j.id == id).firstOrNull;
    if (job == null || !job.terminal) return;
    _queue.remove(id);
    if (!_queue.jobs.any((j) => j.id == id)) {
      _canceledRemaining.remove(id);
      unawaited(_singleFileRetryReleases.remove(id));
      _singleFileRetries.removeWhere((key, value) => key.$1 == id || value.$2 == id);
      ref.notifier(sendProvider).closeSession(id);
    }
  }

  void retry(SendJob job) {
    final current = state.where((entry) => entry.id == job.id).firstOrNull;
    if (current == null ||
        !current.terminal ||
        current.status == SendJobStatus.succeeded ||
        current.recoveryChecking ||
        _deleting.contains(job.id) ||
        _ending.contains(job.id)) {
      return;
    }
    if (current.restored) {
      unawaited(resumeRecovered(current));
      return;
    }
    final remaining = ref.read(sendProvider).containsKey(current.id) ? _remaining(current) : (_canceledRemaining[current.id] ?? current.files);
    if (remaining.isNotEmpty) {
      // remainingSendFiles returns original objects, not filename matches.
      final indices = [for (final file in remaining) current.files.indexWhere((entry) => identical(entry, file))];
      final keys = current.resumeKeys.length == current.files.length && indices.every((index) => index >= 0)
          ? [
              for (final index in indices)
                ref.notifier(sourceEndProvider).keyEndedForJob(current, current.target.fingerprint, current.resumeKeys[index])
                    ? const Uuid().v4()
                    : current.resumeKeys[index],
            ]
          : null;
      _queue.enqueue(current.target, remaining, selectedChannel: current.selectedChannel, localRoute: current.localRoute, resumeKeys: keys);
    }
  }

  bool _disposed = false;
  Future<void>? _initialization;
  SendRecoveryStore? _store;
  Future<void> _recoveryClosed = Future<void>.value();
  Future<void> get recoveryClosed => _recoveryClosed;
  final _captures = <String, Future<SendJob?>>{};
  final _persisted = <String>{};
  final _deleting = <String>{};
  final _ending = <String>{};
  final _checking = <String>{};
  final _lastProgress = <String, (Set<int>, Set<int>)>{};
  FileTransferNotifier? _progress;
  final _attemptIndices = <String, List<int>>{};
  Timer? _checkpointTimer;
  Future<void> _checkpointTail = Future<void>.value();

  void _issue(String code) {
    if (!_disposed) ref.notifier(sendRecoveryIssueProvider).report(code);
  }

  Future<void> initializeRecovery() => _initialization ??= _initializeRecovery();

  Future<void> _initializeRecovery() async {
    final store = ref.read(sendRecoveryStoreProvider);
    if (store == null) return;
    try {
      await store.claimSession();
      if (_disposed) {
        await store.releaseSession();
        return;
      }
      _store = store;
      final restored = await store.load();
      if (_disposed) return;
      _persisted.addAll(restored.map((job) => job.id));
      _queue.restore(restored);
      if (store.issues.isNotEmpty) _issue('corrupt');
    } catch (error) {
      _issue(error is SendRecoveryException && error.code == 'busy' ? 'recoveryInUse' : 'storage');
    }
    if (!_disposed && _store != null) {
      _progress = ref.notifier(fileTransferProvider)..addResultListener(_scheduleCheckpoint);
    }
  }

  void _publish(List<SendJob> jobs) {
    state = jobs;
    if (_store == null || _disposed) return;
    // Persist queued jobs as well as the running job; a FIFO wait must survive.
    for (final job in jobs) {
      if (!job.restored && !_captures.containsKey(job.id) && !_deleting.contains(job.id)) {
        unawaited(_capture(job));
      }
    }
  }

  Future<SendJob?> _capture(SendJob job) {
    if (_store == null || job.restored) return Future<SendJob?>.value(job);
    return _captures.putIfAbsent(job.id, () => _captureSource(job));
  }

  Future<SendJob?> _captureSource(SendJob job) async {
    try {
      final saved = await _store!.saveManifest(job);
      if (_disposed) return saved;
      _persisted.add(job.id);
      final current = state.where((entry) => entry.id == job.id).firstOrNull;
      if (current != null) {
        _queue.update(saved.withStatus(current.status, result: current.result, error: current.error));
      }
      return saved;
    } catch (_) {
      _issue('storage');
      return null;
    }
  }

  void _scheduleCheckpoint() {
    if (_disposed || _store == null || _checkpointTimer != null) return;
    _checkpointTimer = Timer(const Duration(milliseconds: 500), () {
      _checkpointTimer = null;
      unawaited(flushRecovery());
    });
  }

  /// Only acknowledged whole-file results enter durable recovery checkpoints.
  /// Progress bytes are not resume offsets. At most one snapshot per 500 ms is
  /// scheduled; terminal attempts flush explicitly before releasing their slot.
  Future<void> flushRecovery() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    final next = _checkpointTail.then((_) => _flushRecovery());
    _checkpointTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _flushRecovery() async {
    final store = _store;
    if (store == null || _disposed) return;
    await Future.wait(_captures.values.toList());
    if (_disposed) return;
    final sessions = ref.read(sendProvider);
    final progress = ref.read(fileTransferProvider);
    for (final snapshot in List<SendJob>.of(state)) {
      if (_disposed) return;
      final job = state.where((entry) => entry.id == snapshot.id).firstOrNull;
      if (job == null) continue;
      if (!_persisted.contains(job.id) || _deleting.contains(job.id)) continue;
      final session = sessions[job.id];
      final indices = _attemptIndices[job.id];
      if (session == null || indices == null || session.files.length != indices.length) continue;
      final completed = <int>{...job.completedIndices}, skipped = <int>{...job.skippedIndices};
      var index = 0;
      for (final file in session.files.values) {
        final status = progress.getStatus(sessionId: job.id, fileId: file.file.id);
        if (status == FileStatus.finished) completed.add(indices[index]);
        if (status == FileStatus.skipped) skipped.add(indices[index]);
        index++;
      }
      final previous = _lastProgress[job.id];
      if (previous != null && setEquals(previous.$1, completed) && setEquals(previous.$2, skipped)) continue;
      try {
        _queue.update(job.withCheckpoints(completed, skipped));
        await store.saveProgress(job.id, completed: completed, skipped: skipped);
        _lastProgress[job.id] = (completed, skipped);
      } catch (_) {
        _issue('storage');
      }
    }
  }

  Future<bool> resumeRecovered(SendJob requested) async {
    await initializeRecovery();
    final job = state.where((entry) => entry.id == requested.id).firstOrNull;
    if (_disposed ||
        job == null ||
        !job.restored ||
        !job.terminal ||
        job.status == SendJobStatus.succeeded ||
        _deleting.contains(job.id) ||
        _ending.contains(job.id) ||
        !_checking.add(job.id)) {
      return false;
    }
    _queue.update(job.withRecovery(checking: true));
    try {
      final store = _store;
      if (store == null) throw StateError('storage');
      _validateLocalRoute(job);
      final peer = job.target.fingerprint.isEmpty ? null : ref.read(nearbyDevicesProvider).allDevices[job.target.fingerprint];
      if (peer == null || peer.fingerprint != job.target.fingerprint) throw StateError('peerUnavailable');
      await store.validateRemaining(job);
      if (_disposed || _deleting.contains(job.id) || _ending.contains(job.id)) return false;
      // Re-read discovery after source checks. Never silently use saved stale IPs.
      final live = ref.read(nearbyDevicesProvider).allDevices[job.target.fingerprint];
      if (live == null) throw StateError('peerUnavailable');
      _validateLocalRoute(job);
      final target = resolveSendTarget(job.target, live, job.selectedChannel);
      if (target.ip == null) throw StateError('peerUnavailable');
      if (job.completedIndices.length + job.skippedIndices.length == job.files.length) return false;
      // One immutable manifest / stable task ID. Each actual attempt still gets
      // a fresh original-protocol remote session and file tokens, avoiding a
      // crash window with two independently resumable replacement journals.
      ref.notifier(sendProvider).closeSession(job.id);
      final end = ref.notifier(sourceEndProvider);
      if (job.resumeKeys.any((key) => end.keyEndedForJob(job, job.target.fingerprint, key))) {
        final remaining = [
          for (var i = 0; i < job.files.length; i++)
            if (!job.completedIndices.contains(i) && !job.skippedIndices.contains(i)) i,
        ];
        _queue.enqueue(
          target,
          [for (final i in remaining) job.files[i]],
          selectedChannel: job.selectedChannel,
          localRoute: job.localRoute,
          resumeKeys: [
            for (final i in remaining) end.keyEndedForJob(job, job.target.fingerprint, job.resumeKeys[i]) ? const Uuid().v4() : job.resumeKeys[i],
          ],
        );
      } else {
        _queue.resume(job.withRecovery());
      }
      return true;
    } catch (error) {
      final code = error is SelectedLocalRouteUnavailable
          ? 'selectedLocalRouteUnavailable'
          : error is SendRecoveryException
          ? error.code
          : error is StateError
          ? error.message.toString()
          : 'storage';
      if (!_disposed) _queue.update(job.withRecovery(issue: code));
      return false;
    } finally {
      _checking.remove(job.id);
      final current = state.where((entry) => entry.id == job.id).firstOrNull;
      if (!_disposed && current != null && current.recoveryChecking) _queue.update(current.withRecovery(issue: current.recoveryIssue));
    }
  }

  Future<void> _removeRecovered(String id) async {
    final job = state.where((entry) => entry.id == id).firstOrNull;
    if (job == null || !job.terminal || job.recoveryChecking || _queue.isRunning(id) || !_deleting.contains(id)) return;
    try {
      await _captures[id];
      await _checkpointTail;
      final root = await _store!.root.resolveSymbolicLinks();
      if (_disposed) return;
      final current = state.where((entry) => entry.id == id).firstOrNull;
      if (current == null || !current.terminal || _queue.isRunning(id)) return;
      final owned = current.files.map((file) => file.path).whereType<String>().where((path) => p.isWithin(root, path)).toSet();
      if (state.any((other) => other.id != id && other.files.any((file) => owned.contains(file.path)))) {
        _issue('busy');
        return;
      }
      if (_persisted.contains(id) || _captures.containsKey(id)) await _store!.remove(id);
      if (!_disposed) _removeMemory(id);
      _persisted.remove(id);
      await ref.notifier(sourceEndProvider).detached(id);
      unawaited(_captures.remove(id));
      _lastProgress.remove(id);
      _attemptIndices.remove(id);
    } catch (_) {
      _issue('storage');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ending.clear();
    _singleFileRetries.clear();
    _singleFileRetryReleases.clear();
    _checkpointTimer?.cancel();
    _progress?.removeResultListener(_scheduleCheckpoint);
    _queue.dispose();
    _recoveryClosed = () async {
      await _initialization;
      await Future.wait(_captures.values.toList());
      await _checkpointTail;
      try {
        await _store?.releaseSession();
      } catch (error) {
        debugPrint('Send recovery session release failed: $error');
      }
    }();
    unawaited(_recoveryClosed);
    super.dispose();
  }
}
