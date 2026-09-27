import 'dart:async';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:uuid/uuid.dart';

/// In-memory per-device FIFO with bounded cross-device concurrency.
/// Cancellation retains the device slot until the in-flight future has drained.
class SendQueue {
  final Future<SessionStatus?> Function(SendJob) execute;
  final FutureOr<void> Function(SendJob) abort;
  final void Function(List<SendJob>) onChanged;
  final int concurrency;
  final _jobs = <SendJob>[];
  final _running = <String, String>{}; // job ID -> stable device key
  bool _disposed = false;
  final _aborting = <String, Future<void>>{};

  SendQueue({required this.execute, required this.abort, required this.onChanged, this.concurrency = 3}) : assert(concurrency > 0);

  List<SendJob> get jobs => List.unmodifiable(_jobs);

  String enqueue(Device target, List<CrossFile> files, {HttpChannel? selectedChannel, LocalSendRoute? localRoute, List<String>? resumeKeys}) {
    if (_disposed) throw StateError('Queue disposed');
    if (files.isEmpty) throw ArgumentError('No files selected');
    if (_jobs.where((j) => !j.terminal).length >= 128) throw StateError('Queue full (128 tasks)');
    final keys = resumeKeys ?? [for (final _ in files) const Uuid().v4()];
    if (keys.length != files.length || keys.toSet().length != keys.length) throw ArgumentError('Invalid recovery keys');
    final id = const Uuid().v4();
    _jobs.add(
      SendJob(
        id: id,
        target: target,
        selectedChannel: selectedChannel,
        localRoute: localRoute,
        resumeKeys: List.unmodifiable(keys),
        files: List.unmodifiable([
          for (final file in files) file.copyWith(bytes: file.bytes == null ? null : List<int>.unmodifiable(file.bytes!)),
        ]),
      ),
    );
    _notify();
    _pump();
    return id;
  }

  /// Publish an already durable, privately captured source manifest.
  String enqueuePrepared(SendJob job) {
    if (_disposed || job.status != SendJobStatus.queued || job.files.isEmpty || _jobs.any((entry) => entry.id == job.id)) {
      throw StateError('Prepared queue task invalid');
    }
    if (_jobs.where((entry) => !entry.terminal).length >= 128) throw StateError('Queue full (128 tasks)');
    _jobs.add(job);
    _notify();
    _pump();
    return job.id;
  }

  bool isRunning(String id) => _running.containsKey(id);

  /// Restore history only; recovered work never enters the automatic pump.
  void restore(Iterable<SendJob> jobs) {
    if (_disposed) return;
    for (final job in jobs) {
      if (!job.terminal || !job.restored) throw ArgumentError('Recovery must be explicitly resumed');
      if (!_jobs.any((entry) => entry.id == job.id)) _jobs.add(job);
    }
    _notify();
  }

  void resume(SendJob job) {
    if (_disposed || isRunning(job.id) || !job.terminal || !job.restored) throw StateError('Recovery is busy');
    if (_jobs.where((entry) => !entry.terminal).length >= 128) throw StateError('Queue full (128 tasks)');
    final index = _jobs.indexWhere((entry) => entry.id == job.id);
    if (index < 0) throw StateError('Recovery was removed');
    final current = _jobs[index];
    if (!current.terminal) throw StateError('Recovery is already queued');
    _jobs.removeAt(index);
    _jobs.add(job.withRecovery().withStatus(SendJobStatus.queued).withAttemptRevision(current.attemptRevision + 1));
    _notify();
    _pump();
  }

  void update(SendJob job) {
    final index = _jobs.indexWhere((entry) => entry.id == job.id);
    if (index >= 0) {
      _jobs[index] = job;
      _notify();
    }
  }

  void cancel(String id) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0 || _jobs[index].terminal) return;
    final job = _jobs[index];
    _jobs[index] = job.withStatus(SendJobStatus.canceled);
    if (_running.containsKey(id)) {
      _aborting[id] = Future<void>.sync(() => abort(job)).catchError((Object _) {});
    }
    _notify();
    _pump();
  }

  void remove(String id) {
    _jobs.removeWhere((j) => j.id == id && j.terminal && !_running.containsKey(id));
    _notify();
  }

  void _notify() {
    if (!_disposed) onChanged(jobs);
  }

  void _pump() {
    if (_disposed) return;
    for (final job in List<SendJob>.of(_jobs)) {
      if (_running.length >= concurrency) break;
      if (job.status != SendJobStatus.queued || _running.containsValue(job.deviceKey)) continue;
      _running[job.id] = job.deviceKey;
      final index = _jobs.indexWhere((j) => j.id == job.id);
      _jobs[index] = job.withStatus(SendJobStatus.running);
      _notify();
      unawaited(_run(job));
    }
  }

  Future<void> _run(SendJob job) async {
    SessionStatus? result;
    String? error;
    try {
      result = await execute(job);
    } catch (e) {
      error = e.toString();
    } finally {
      await _aborting.remove(job.id);
      _running.remove(job.id);
      final index = _jobs.indexWhere((j) => j.id == job.id);
      if (index >= 0 && _jobs[index].status != SendJobStatus.canceled) {
        final status = error != null
            ? SendJobStatus.failed
            : switch (result) {
                SessionStatus.finished => SendJobStatus.succeeded,
                SessionStatus.canceledBySender || SessionStatus.canceledByReceiver || null => SendJobStatus.canceled,
                SessionStatus.connectionLost => SendJobStatus.failed,
                SessionStatus.sourceEnded => SendJobStatus.failed,
                _ => SendJobStatus.failed,
              };
        _jobs[index] = _jobs[index].withStatus(status, result: result, error: error);
      }
      _notify();
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    for (final job in _jobs.where((j) => _running.containsKey(j.id))) {
      unawaited(Future<void>.sync(() => abort(job)).catchError((Object _) {}));
    }
  }
}
