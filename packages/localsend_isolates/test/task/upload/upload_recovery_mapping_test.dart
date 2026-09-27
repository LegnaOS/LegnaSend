import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/util/upload_recovery.dart';

void main() {
  test('all typed failure and retention variants map without free-form parsing', () {
    for (final kind in RsRecoveryFailureKind.values) {
      for (final retention in RsRecoveryRetention.values) {
        final mapped = classifyUploadRecovery(RsHttpClientError.recovery(kind: kind, retention: retention, status: 403))!;
        expect(mapped.kind.name, kind.name);
        expect(mapped.retention.name, retention.name);
        expect(mapped.status, 403);
        expect(mapped.retainedConfirmed, switch (retention) {
          RsRecoveryRetention.notRetained => null,
          RsRecoveryRetention.unknown => false,
          RsRecoveryRetention.confirmed => true,
        });
      }
    }
  });
  test('legacy typed interruption remains compatible; legacy status/message does not prove source termination', () {
    for (final retained in [false, true]) {
      final mapped = classifyUploadRecovery(RsHttpClientError.resumeInterrupted(retainedConfirmed: retained))!;
      expect(mapped.kind, UploadRecoveryFailureKind.retryable);
      expect(mapped.retainedConfirmed, retained);
    }
    for (final code in [401, 403, 404, 410, 503]) {
      expect(classifyUploadRecovery(RsHttpClientError.statusCode(status: code, message: 'sourceChanged retainedConfirmed')), isNull);
    }
    expect(classifyUploadRecovery('authorizationRequired'), isNull);
  });
  test('waiting bounds and terminal HTTP status validate independently of transfer bytes', () {
    expect(const UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 1000).valid, true);
    expect(const UploadRecoveryState.waiting(attempt: 0, retryAfterMs: 1000).valid, false);
    expect(const UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 999999).valid, false);
    expect(
      const UploadRecoveryState.failed(
        UploadRecoveryFailure(
          kind: UploadRecoveryFailureKind.invalidResponse,
          retention: UploadRecoveryRetention.unknown,
          status: 999,
        ),
      ).valid,
      false,
    );
  });
}
