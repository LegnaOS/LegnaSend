/// Optional native recovery metadata. These values never alter LocalSend's
/// original file/session status, upload offsets, or verification byte counts.
enum UploadRecoveryFailureKind { retryable, authorizationRequired, sourceChanged, invalidResponse }

enum UploadRecoveryRetention { notRetained, unknown, confirmed }

class UploadRecoveryFailure {
  final UploadRecoveryFailureKind kind;
  final UploadRecoveryRetention retention;
  final int? status;
  const UploadRecoveryFailure({required this.kind, required this.retention, this.status});

  /// Preserve the existing remote-release guard for unknown retained data.
  bool? get retainedConfirmed => switch (retention) {
    UploadRecoveryRetention.notRetained => null,
    UploadRecoveryRetention.unknown => false,
    UploadRecoveryRetention.confirmed => true,
  };
}

class UploadRecoveryState {
  final UploadRecoveryFailure? failure;
  final int attempt;
  final int retryAfterMs;
  const UploadRecoveryState.waiting({required this.attempt, required this.retryAfterMs}) : failure = null;
  const UploadRecoveryState.failed(this.failure) : attempt = 0, retryAfterMs = 0;
  bool get waiting => failure == null;
  bool get valid => waiting
      ? attempt > 0 && attempt <= 255 && retryAfterMs > 0 && retryAfterMs <= 60000
      : failure!.status == null || (failure!.status! >= 100 && failure!.status! <= 599);
}
