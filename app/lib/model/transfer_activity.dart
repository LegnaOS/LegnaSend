import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';

enum TransferActivityKind { native, webResponse, webApproval }

enum TransferDirection { send, receive }

enum TransferPhase { queued, preparing, waiting, transferring, succeeded, failed, canceled, unconfirmed, retrying, sourceEnded }

class TransferActivityFile {
  final String name;
  final int size;
  final int transferred;
  const TransferActivityFile(this.name, this.size, this.transferred);
}

class TransferActivity {
  final String id;
  final TransferActivityKind kind;
  final bool totalKnown;
  final TransferDirection direction;
  final TransferPhase phase;
  final String peer;
  final List<TransferActivityFile> files;
  final String? error;
  final SendJob? job;
  final int? resultRevision;
  final String? workspaceId;
  final String? workspaceName;
  final String? operation;
  final String? origin;
  final FileVerification? verification;
  final UploadRecoveryState? recovery;

  const TransferActivity({
    required this.id,
    this.kind = TransferActivityKind.native,
    this.totalKnown = true,
    required this.direction,
    required this.phase,
    required this.peer,
    required this.files,
    this.error,
    this.job,
    this.resultRevision,
    this.workspaceId,
    this.workspaceName,
    this.operation,
    this.origin,
    this.verification,
    this.recovery,
  });
  String get key => '${kind == TransferActivityKind.native ? '' : '${kind.name}:'}${direction.name}:$id';
  // A recovered job can fail during preparation before a SendSessionState (and
  // endTime) exists. Its queue incarnation still identifies a new result.
  String get resultKey =>
      '$key:${phase.name}${job == null ? '' : ':attempt-${job!.attemptRevision}'}${resultRevision == null ? '' : ':$resultRevision'}';
  bool get active =>
      phase == TransferPhase.queued || phase == TransferPhase.preparing || phase == TransferPhase.waiting || phase == TransferPhase.transferring || phase == TransferPhase.retrying;
  bool get needsAttention =>
      phase == TransferPhase.failed ||
      phase == TransferPhase.sourceEnded ||
      phase == TransferPhase.unconfirmed ||
      (kind == TransferActivityKind.webApproval && phase == TransferPhase.waiting) ||
      (direction == TransferDirection.receive && phase == TransferPhase.waiting);
  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  int get transferredBytes => files.fold(0, (sum, f) => sum + f.transferred);
  double get progress => totalBytes == 0 ? (phase == TransferPhase.succeeded ? 1 : 0) : (transferredBytes / totalBytes).clamp(0, 1);
}

TransferPhase _phase(SessionStatus status) => switch (status) {
  SessionStatus.waiting => TransferPhase.waiting,
  SessionStatus.sending => TransferPhase.transferring,
  SessionStatus.finished => TransferPhase.succeeded,
  SessionStatus.canceledBySender || SessionStatus.canceledByReceiver => TransferPhase.canceled,
  SessionStatus.connectionLost => TransferPhase.retrying,
  SessionStatus.sourceEnded => TransferPhase.sourceEnded,
  _ => TransferPhase.failed,
};

List<TransferActivity> collectTransferActivities({
  required List<SendJob> jobs,
  required Map<String, SendSessionState> sends,
  required ReceiveSessionState? receive,
  required FileTransferNotifier progress,
}) {
  int bytes(String session, String file, int size, TransferPhase phase) {
    if (phase == TransferPhase.preparing || phase == TransferPhase.waiting || phase == TransferPhase.queued) return 0;
    final status = progress.getStatus(sessionId: session, fileId: file);
    if (status == FileStatus.queue ||
        status == FileStatus.skipped ||
        status == FileStatus.failed && progress.getRecovery(sessionId: session, fileId: file)?.failure == null) {
      return 0;
    }
    if (status == FileStatus.finished) return size;
    return (progress.getProgress(sessionId: session, fileId: file).clamp(0, 1) * size).round();
  }

  TransferActivity outgoing(SendSessionState session, SendJob? job, {TransferPhase? overridePhase}) {
    final phase =
        overridePhase ??
        (session.status == SessionStatus.waiting && session.hashedFileCount < session.files.length
            ? TransferPhase.preparing
            : _phase(session.status));
    // A recovered live session contains only the unfinished subset. Retain the
    // immutable manifest and use the actual attempt map rather than names/paths:
    // duplicate selections may otherwise steal each other's completion credit.
    List<TransferActivityFile>? restoredFiles;
    if (job != null && job.restored) {
      final liveByIndex = <int, SendingFile>{};
      final indices = job.attemptIndices;
      if (indices != null && indices.length == session.files.length) {
        var offset = 0;
        for (final file in session.files.values) {
          final index = indices[offset++];
          if (index >= 0 && index < job.files.length) liveByIndex[index] = file;
        }
      }
      restoredFiles = [];
      for (var index = 0; index < job.files.length; index++) {
        final source = job.files[index];
        final live = liveByIndex[index];
        final status = live == null ? null : progress.getStatus(sessionId: session.sessionId, fileId: live.file.id);
        if (job.skippedIndices.contains(index) || status == FileStatus.skipped) continue;
        final transferred = job.completedIndices.contains(index)
            ? source.size
            : live == null
            ? 0
            : bytes(session.sessionId, live.file.id, source.size, phase);
        restoredFiles.add(TransferActivityFile(source.name, source.size, transferred));
      }
    }
    return TransferActivity(
      id: session.sessionId,
      direction: TransferDirection.send,
      phase: phase,
      peer: session.target.alias,
      error: job?.error ?? session.errorMessage,
      job: job,
      resultRevision: session.endTime,
      verification: progress.verificationForSession(session.sessionId),
      recovery: progress.recoveryForSession(session.sessionId),
      files:
          restoredFiles ??
          [
            for (final f in session.files.values)
              if (progress.getStatus(sessionId: session.sessionId, fileId: f.file.id) != FileStatus.skipped)
                TransferActivityFile(f.file.fileName, f.file.size, bytes(session.sessionId, f.file.id, f.file.size, phase)),
          ],
    );
  }

  final activities = <TransferActivity>[];
  final jobIds = jobs.map((j) => j.id).toSet();
  for (final job in jobs) {
    final session = sends[job.id];
    if (session != null && job.status == SendJobStatus.running) {
      activities.add(outgoing(session, job));
      continue;
    }
    final phase = switch (job.status) {
      SendJobStatus.queued => TransferPhase.queued,
      SendJobStatus.running => TransferPhase.preparing,
      SendJobStatus.succeeded => TransferPhase.succeeded,
      SendJobStatus.failed => TransferPhase.failed,
      SendJobStatus.canceled => TransferPhase.canceled,
    };
    if (session != null) {
      activities.add(outgoing(session, job, overridePhase: phase));
      continue;
    }
    activities.add(
      TransferActivity(
        id: job.id,
        direction: TransferDirection.send,
        phase: phase,
        peer: job.target.alias,
        error: job.error ?? session?.errorMessage,
        job: job,
        files: [
          for (var index = 0; index < job.files.length; index++)
            if (!job.skippedIndices.contains(index))
              TransferActivityFile(job.files[index].name, job.files[index].size, job.completedIndices.contains(index) ? job.files[index].size : 0),
        ],
      ),
    );
  }
  for (final session in sends.values) {
    if (!jobIds.contains(session.sessionId)) activities.add(outgoing(session, null));
  }
  if (receive != null) {
    final phase = _phase(receive.status);
    activities.add(
      TransferActivity(
        id: receive.sessionId,
        direction: TransferDirection.receive,
        phase: phase,
        peer: receive.senderAlias,
        verification: progress.verificationForSession(receive.sessionId),
        resultRevision: receive.endTime,
        files: [
          for (final f in receive.files.values)
            if (receive.status == SessionStatus.waiting || f.desiredName != null)
              TransferActivityFile(f.desiredName ?? f.file.fileName, f.file.size, bytes(receive.sessionId, f.file.id, f.file.size, phase)),
        ],
        error: receive.files.values.map((f) => f.errorMessage).whereType<String>().firstOrNull,
      ),
    );
  }
  return activities;
}

/// Only actual transfers contribute bytes; checksum work and history do not.
double? activeTransferProgress(Iterable<TransferActivity> tasks, TransferDirection direction) {
  final transferring = tasks.where((t) => t.direction == direction && t.phase == TransferPhase.transferring);
  final total = transferring.fold<int>(0, (sum, t) => sum + t.totalBytes);
  if (total == 0 || transferring.any((task) => !task.totalKnown)) return null;
  return (transferring.fold<int>(0, (sum, t) => sum + t.transferredBytes) / total).clamp(0, 1);
}
