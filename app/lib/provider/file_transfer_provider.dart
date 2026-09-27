import 'dart:async';

import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// A provider holding the live per-file transfer state (status and progress).
/// It is implemented as [ChangeNotifier] for performance reasons:
/// a status or progress update does not need to copy the whole session state.
final fileTransferProvider = ChangeNotifierProvider((ref) => FileTransferNotifier());

class FileTransfer {
  FileStatus status;
  double progress; // 0..1
  String? receiveAttemptId;
  int? receiveOwner;
  FileVerification? verification;
  UploadRecoveryState? recovery;
  bool receiveTransportStarted = false;

  FileTransfer(this.status) : progress = 0;

  @override
  String toString() => '($status, $progress)';
}

enum TransferProgressScope { all, send, receive }

class _ProgressProjection {
  final Map<String, int> sizes;
  int bytes = 0;
  final counts = <FileStatus, int>{};
  _ProgressProjection(this.sizes);
}

class _SessionTotals {
  final projections = <TransferProgressScope, _ProgressProjection>{};
  final counts = <FileStatus, int>{};
}

class FileTransferNotifier extends ChangeNotifier {
  /// Presentation only. State and result callbacks remain synchronous.
  static const presentationInterval = Duration(milliseconds: 100);
  Timer? _presentationTimer;
  bool _disposed = false;
  bool _initializedForPresentation = false;

  @override
  void postInit() {
    super.postInit();
    _initializedForPresentation = true;
  }

  final _totals = <String, _SessionTotals>{};

  void _present() {
    if (_disposed || !_initializedForPresentation || _presentationTimer != null) return;
    _presentationTimer = Timer(presentationInterval, () {
      _presentationTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _presentRemoval() {
    _presentationTimer?.cancel();
    _presentationTimer = null;
    if (!_disposed) notifyListeners();
  }

  FileTransfer _file(String sessionId, String fileId) {
    return _sessionMap.putIfAbsent(sessionId, () => {}).putIfAbsent(fileId, () {
      final totals = _totals.putIfAbsent(sessionId, _SessionTotals.new);
      totals.counts.update(FileStatus.queue, (count) => count + 1, ifAbsent: () => 1);
      for (final projection in totals.projections.values) {
        if (projection.sizes.containsKey(fileId)) {
          projection.counts.update(FileStatus.queue, (count) => count + 1, ifAbsent: () => 1);
        }
      }
      return FileTransfer(FileStatus.queue);
    });
  }

  /// Register immutable display membership once. Metadata must not introduce
  /// pending protocol files. At most three projections exist per session.
  void registerFileSizes(String sessionId, Map<String, int> sizes, {TransferProgressScope scope = TransferProgressScope.all}) {
    if (_disposed) return;
    final projection = _ProgressProjection({
      for (final entry in sizes.entries)
        if (entry.value >= 0) entry.key: entry.value,
    });
    for (final entry in projection.sizes.entries) {
      final file = _sessionMap[sessionId]?[entry.key];
      if (file == null) continue;
      projection.bytes += (entry.value * file.progress).round();
      projection.counts.update(file.status, (count) => count + 1, ifAbsent: () => 1);
    }
    _totals.putIfAbsent(sessionId, _SessionTotals.new).projections[scope] = projection;
  }

  int transferredBytes(String sessionId, {TransferProgressScope scope = TransferProgressScope.all}) =>
      _totals[sessionId]?.projections[scope]?.bytes ?? 0;
  int statusCount(String sessionId, FileStatus status, {TransferProgressScope? scope}) =>
      (scope == null ? _totals[sessionId]?.counts[status] : _totals[sessionId]?.projections[scope]?.counts[status]) ?? 0;

  bool hasPending(String sessionId) => statusCount(sessionId, FileStatus.queue) != 0 || statusCount(sessionId, FileStatus.sending) != 0;
  bool hasFailed(String sessionId) => statusCount(sessionId, FileStatus.failed) != 0;

  SessionStatus classifyFailure(String sessionId) {
    final files = _sessionMap[sessionId];
    if (files == null) return SessionStatus.finishedWithErrors;
    bool anySourceChanged = false;
    bool allRetryable = true;
    bool anyFailed = false;
    for (final file in files.values) {
      if (file.status != FileStatus.failed) continue;
      anyFailed = true;
      final kind = file.recovery?.failure?.kind;
      if (kind == UploadRecoveryFailureKind.sourceChanged) {
        anySourceChanged = true;
        break;
      }
      if (kind != UploadRecoveryFailureKind.retryable) allRetryable = false;
    }
    if (!anyFailed) return SessionStatus.finished;
    if (anySourceChanged) return SessionStatus.sourceEnded;
    if (allRetryable) return SessionStatus.connectionLost;
    return SessionStatus.finishedWithErrors;
  }

  void _status(String sessionId, String fileId, FileStatus status) {
    final file = _file(sessionId, fileId);
    final counts = _totals[sessionId]!.counts;
    if (file.status != status) {
      counts[file.status] = (counts[file.status] ?? 0) - 1;
      counts.update(status, (count) => count + 1, ifAbsent: () => 1);
      for (final projection in _totals[sessionId]!.projections.values) {
        if (!projection.sizes.containsKey(fileId)) continue;
        projection.counts[file.status] = (projection.counts[file.status] ?? 0) - 1;
        projection.counts.update(status, (count) => count + 1, ifAbsent: () => 1);
      }
      file.status = status;
    }
    if (status != FileStatus.sending) file.verification = null;
    if (status != FileStatus.sending && (status != FileStatus.failed || file.recovery?.waiting != false)) file.recovery = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _presentationTimer?.cancel();
    _presentationTimer = null;
    _sessionMap.clear();
    _totals.clear();
    _resultListeners.clear();
    super.dispose();
  }

  final _resultListeners = <void Function()>{};
  void addResultListener(void Function() listener) => _resultListeners.add(listener);
  void removeResultListener(void Function() listener) => _resultListeners.remove(listener);
  void _notifyResults() {
    for (final listener in List<void Function()>.of(_resultListeners)) {
      listener();
    }
  }

  final _sessionMap = <String, Map<String, FileTransfer>>{}; // session id -> (file id -> live transfer state)

  void setStatus({required String sessionId, required String fileId, required FileStatus status}) {
    if (_disposed) return;
    _status(sessionId, fileId, status);
    _present();
    _notifyResults();
  }

  /// State and result listeners are updated synchronously, presentation once.
  void setStatuses({required String sessionId, required Map<String, FileStatus> statuses}) {
    if (_disposed) return;
    for (final entry in statuses.entries) {
      _status(sessionId, entry.key, entry.value);
    }
    _present();
    _notifyResults();
  }

  void setProgress({required String sessionId, required String fileId, required double progress}) {
    if (_disposed || !progress.isFinite) return;
    final file = _file(sessionId, fileId);
    final next = progress.clamp(0.0, 1.0).toDouble();
    for (final projection in _totals[sessionId]!.projections.values) {
      final size = projection.sizes[fileId];
      if (size != null) projection.bytes += (size * next).round() - (size * file.progress).round();
    }
    file.progress = next;
    _present();
  }

  void beginReceiveAttempt({required String sessionId, required String fileId, required String? attemptId, required int owner}) {
    if (_disposed) return;
    final file = _file(sessionId, fileId);
    file.receiveAttemptId = attemptId;
    file.receiveOwner = owner;
    file.receiveTransportStarted = false;
    file.verification = null;
    file.recovery = null;
  }

  void beginVerificationAttempt({required String sessionId, required String fileId, required String? attemptId, int owner = 0}) =>
      beginReceiveAttempt(sessionId: sessionId, fileId: fileId, attemptId: attemptId, owner: owner);

  bool ownsReceiveAttempt({required String sessionId, required String fileId, required String? attemptId, required int owner}) {
    final file = _sessionMap[sessionId]?[fileId];
    // Null is the original protocol path. Existing callers without an explicit
    // attempt still work, but cannot update a current durable attempt.
    return file?.receiveAttemptId == attemptId && (file?.receiveOwner == null || file!.receiveOwner == owner);
  }

  bool markReceiveTransportStarted({required String sessionId, required String fileId}) {
    final file = _sessionMap[sessionId]?[fileId];
    if (file == null || file.receiveTransportStarted) return false;
    file.receiveTransportStarted = true;
    return true;
  }

  bool setVerification({required String sessionId, required String fileId, int owner = 0, required FileVerification value, required bool verifying}) {
    final file = _sessionMap[sessionId]?[fileId];
    if (file == null ||
        file.status != FileStatus.sending ||
        !value.valid ||
        !ownsReceiveAttempt(sessionId: sessionId, fileId: fileId, attemptId: value.attemptId, owner: owner)) {
      return false;
    }
    file.verification = verifying ? value : null;
    _present();
    return true;
  }

  bool setRecovery({required String sessionId, required String fileId, required String attemptId, required UploadRecoveryState? value}) {
    final file = _sessionMap[sessionId]?[fileId];
    if (file == null ||
        !ownsReceiveAttempt(sessionId: sessionId, fileId: fileId, attemptId: attemptId, owner: 0) ||
        value != null && !value.valid ||
        (value?.waiting == true ? file.status != FileStatus.sending : !{FileStatus.sending, FileStatus.failed}.contains(file.status))) {
      return false;
    }
    file.recovery = value;
    _present();
    return true;
  }

  void clearWaitingRecovery(String sessionId) {
    var changed = false;
    for (final file in _sessionMap[sessionId]?.values ?? const <FileTransfer>[]) {
      if (file.recovery?.waiting == true) {
        file.recovery = null;
        changed = true;
      }
    }
    if (changed) _present();
  }

  UploadRecoveryState? getRecovery({required String sessionId, required String fileId}) => _sessionMap[sessionId]?[fileId]?.recovery;

  UploadRecoveryState? recoveryForSession(String sessionId) {
    UploadRecoveryState? selected;
    int priority(UploadRecoveryState value) => switch (value.failure?.kind) {
      UploadRecoveryFailureKind.sourceChanged => 5,
      UploadRecoveryFailureKind.authorizationRequired => 4,
      UploadRecoveryFailureKind.invalidResponse => 3,
      UploadRecoveryFailureKind.retryable => 2,
      null => 1,
    };
    for (final file in _sessionMap[sessionId]?.values ?? const <FileTransfer>[]) {
      final value = file.recovery;
      if (value != null && (selected == null || priority(value) > priority(selected))) selected = value;
    }
    return selected;
  }

  void clearVerifications(String sessionId, {String? fileId}) {
    final files = _sessionMap[sessionId];
    if (files == null) return;
    var changed = false;
    for (final entry in files.entries) {
      if ((fileId == null || entry.key == fileId) && entry.value.verification != null) {
        entry.value.verification = null;
        changed = true;
      }
    }
    if (changed) _present();
  }

  FileVerification? getVerification({required String sessionId, required String fileId}) => _sessionMap[sessionId]?[fileId]?.verification;

  FileVerification? verificationForSession(String sessionId) {
    final values = _sessionMap[sessionId]?.values.map((file) => file.verification).whereType<FileVerification>().toList();
    if (values == null || values.isEmpty) return null;
    return FileVerification(
      attemptId: 'aggregate',
      receiving: values.first.receiving,
      verifiedBytes: values.fold(0, (sum, value) => sum + value.verifiedBytes),
      totalBytes: values.fold(0, (sum, value) => sum + value.totalBytes),
    );
  }

  FileStatus getStatus({required String sessionId, required String fileId}) {
    return _sessionMap[sessionId]?[fileId]?.status ?? FileStatus.queue;
  }

  Iterable<FileStatus> getStatuses(String sessionId) {
    return _sessionMap[sessionId]?.values.map((file) => file.status) ?? const [];
  }

  double getProgress({required String sessionId, required String fileId}) {
    return _sessionMap[sessionId]?[fileId]?.progress ?? 0.0;
  }

  void removeSession(String sessionId) {
    _sessionMap.remove(sessionId);
    _totals.remove(sessionId);
    _presentRemoval();
  }

  void removeAllSessions() {
    _sessionMap.clear();
    _totals.clear();
    _presentRemoval();
  }

  /// Only for debug purposes
  Map<String, Map<String, FileTransfer>> getData() {
    return _sessionMap;
  }
}
