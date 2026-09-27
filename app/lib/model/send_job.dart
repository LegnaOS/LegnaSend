import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';

enum SendJobStatus { queued, running, succeeded, failed, canceled }

class SendJob {
  final String id;
  final Device target;
  final HttpChannel? selectedChannel;
  final LocalSendRoute? localRoute;
  final List<CrossFile> files;

  /// Stable per immutable source; only advertised after its manifest was saved.
  final List<String> resumeKeys;
  final bool resumeKeysPersisted;
  final SendJobStatus status;
  final SessionStatus? result;
  final String? error;
  final bool restored;
  final Set<int> completedIndices;
  final Set<int> skippedIndices;
  final String? recoveryIssue;
  final bool recoveryChecking;

  /// In-memory incarnation for a stable recovered task ID. Increment before a
  /// resumed attempt can enter the queue, not when byte transfer finally starts.
  final int attemptRevision;

  /// Maps live session selection order back to the immutable full manifest.
  /// Ephemeral: each new attempt reconstructs this map before creating a session.
  final List<int>? attemptIndices;

  const SendJob({
    required this.id,
    required this.target,
    required this.files,
    this.resumeKeys = const [],
    this.resumeKeysPersisted = false,
    this.selectedChannel,
    this.localRoute,
    this.status = SendJobStatus.queued,
    this.result,
    this.error,
    this.restored = false,
    this.completedIndices = const {},
    this.skippedIndices = const {},
    this.recoveryIssue,
    this.recoveryChecking = false,
    this.attemptIndices,
    this.attemptRevision = 0,
  });

  String get deviceKey => target.fingerprint.isNotEmpty ? target.fingerprint : '${target.ip}:${target.port}:${target.https}';
  bool get terminal => status != SendJobStatus.queued && status != SendJobStatus.running;

  SendJob withStatus(SendJobStatus status, {SessionStatus? result, String? error}) => SendJob(
    id: id,
    target: target,
    selectedChannel: selectedChannel,
    localRoute: localRoute,
    files: files,
    resumeKeys: resumeKeys,
    resumeKeysPersisted: resumeKeysPersisted,
    status: status,
    result: result,
    error: error,
    restored: restored,
    completedIndices: completedIndices,
    skippedIndices: skippedIndices,
    recoveryIssue: recoveryIssue,
    recoveryChecking: recoveryChecking,
    attemptIndices: attemptIndices,
    attemptRevision: attemptRevision,
  );

  SendJob withRecovery({String? issue, bool checking = false}) => SendJob(
    id: id,
    target: target,
    selectedChannel: selectedChannel,
    localRoute: localRoute,
    files: files,
    resumeKeys: resumeKeys,
    resumeKeysPersisted: resumeKeysPersisted,
    status: status,
    result: result,
    error: error,
    restored: restored,
    completedIndices: completedIndices,
    skippedIndices: skippedIndices,
    recoveryIssue: issue,
    recoveryChecking: checking,
    attemptIndices: attemptIndices,
    attemptRevision: attemptRevision,
  );
  SendJob withCheckpoints(Set<int> completed, Set<int> skipped) => SendJob(
    id: id,
    target: target,
    selectedChannel: selectedChannel,
    localRoute: localRoute,
    files: files,
    resumeKeys: resumeKeys,
    resumeKeysPersisted: resumeKeysPersisted,
    status: status,
    result: result,
    error: error,
    restored: restored,
    completedIndices: Set.unmodifiable(completed),
    skippedIndices: Set.unmodifiable(skipped),
    recoveryIssue: recoveryIssue,
    recoveryChecking: recoveryChecking,
    attemptIndices: attemptIndices,
    attemptRevision: attemptRevision,
  );
  SendJob withAttempt(List<int> indices) => SendJob(
    id: id,
    target: target,
    selectedChannel: selectedChannel,
    localRoute: localRoute,
    files: files,
    resumeKeys: resumeKeys,
    resumeKeysPersisted: resumeKeysPersisted,
    status: status,
    result: result,
    error: error,
    restored: restored,
    completedIndices: completedIndices,
    skippedIndices: skippedIndices,
    recoveryIssue: recoveryIssue,
    recoveryChecking: recoveryChecking,
    attemptIndices: List.unmodifiable(indices),
    attemptRevision: attemptRevision,
  );

  SendJob withAttemptRevision(int revision) => SendJob(
    id: id,
    target: target,
    selectedChannel: selectedChannel,
    localRoute: localRoute,
    files: files,
    resumeKeys: resumeKeys,
    resumeKeysPersisted: resumeKeysPersisted,
    status: status,
    result: result,
    error: error,
    restored: restored,
    completedIndices: completedIndices,
    skippedIndices: skippedIndices,
    recoveryIssue: recoveryIssue,
    recoveryChecking: recoveryChecking,
    attemptIndices: attemptIndices,
    attemptRevision: revision,
  );
}
