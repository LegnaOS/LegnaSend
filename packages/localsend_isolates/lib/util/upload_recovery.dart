import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/rust/api/http.dart';

/// Never classify by a free-form error body. A legacy HTTP status alone cannot
/// establish source termination or prove whether a receiver retained its cache.
UploadRecoveryFailure? classifyUploadRecovery(Object error) => switch (error) {
  RsHttpClientError_Recovery(:final kind, :final retention, :final status) => UploadRecoveryFailure(
    kind: switch (kind) {
      RsRecoveryFailureKind.retryable => UploadRecoveryFailureKind.retryable,
      RsRecoveryFailureKind.authorizationRequired => UploadRecoveryFailureKind.authorizationRequired,
      RsRecoveryFailureKind.sourceChanged => UploadRecoveryFailureKind.sourceChanged,
      RsRecoveryFailureKind.invalidResponse => UploadRecoveryFailureKind.invalidResponse,
    },
    retention: switch (retention) {
      RsRecoveryRetention.notRetained => UploadRecoveryRetention.notRetained,
      RsRecoveryRetention.unknown => UploadRecoveryRetention.unknown,
      RsRecoveryRetention.confirmed => UploadRecoveryRetention.confirmed,
    },
    status: status,
  ),
  RsHttpClientError_ResumeInterrupted(:final retainedConfirmed) => UploadRecoveryFailure(
    kind: UploadRecoveryFailureKind.retryable,
    retention: retainedConfirmed ? UploadRecoveryRetention.confirmed : UploadRecoveryRetention.unknown,
  ),
  _ => null,
};
