import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';

String uploadRecoveryLabel(UploadRecoveryState state) => switch (state.failure?.kind) {
  null => t.transferActivity.recoveryWaiting,
  UploadRecoveryFailureKind.retryable => t.transferActivity.recoveryRetryable,
  UploadRecoveryFailureKind.authorizationRequired => t.transferActivity.recoveryAuthorization,
  UploadRecoveryFailureKind.sourceChanged => t.transferActivity.recoverySourceChanged,
  UploadRecoveryFailureKind.invalidResponse => t.transferActivity.recoveryInvalidResponse,
};

String uploadRecoveryRetentionLabel(UploadRecoveryRetention value) => switch (value) {
  UploadRecoveryRetention.confirmed => t.transferActivity.recoveryRetained,
  UploadRecoveryRetention.unknown => t.transferActivity.recoveryRetentionUnknown,
  UploadRecoveryRetention.notRetained => t.transferActivity.recoveryNotRetained,
};

String uploadRecoveryMessage(UploadRecoveryFailure failure) =>
    '${uploadRecoveryLabel(UploadRecoveryState.failed(failure))} · ${uploadRecoveryRetentionLabel(failure.retention)}';
