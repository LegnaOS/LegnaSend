import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('verification is isolated from transport bytes, stale attempts, listener owners and concurrent send', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    var owner = 1;
    ServerState? state = ServerState(alias: 'Self', port: 1, https: false, session: incoming('receive'), web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
        getListenerGeneration: () => owner,
      ),
    );
    final progress = container.notifier(fileTransferProvider);
    final file = rust.FileDto(id: 'in', fileName: 'in.bin', size: BigInt.from(100), fileType: 'application/octet-stream');
    void begin(String attempt) =>
        controller.onFileUpload(HttpServerFileUploadEvent(sessionId: 'receive', fileId: 'in', file: file, attemptId: attempt));
    void verify(String attempt, {int bytes = 70, int total = 100, bool active = true}) => controller.onFileVerification(
      HttpServerFileVerificationEvent(
        sessionId: 'receive',
        fileId: 'in',
        attemptId: attempt,
        verifiedBytes: bytes,
        totalBytes: total,
        verifying: active,
      ),
    );
    progress.setProgress(sessionId: 'send', fileId: 'out', progress: 0.33);
    progress.setStatus(sessionId: 'send', fileId: 'out', status: FileStatus.sending);
    begin('old');
    verify('old');
    expect(progress.getVerification(sessionId: 'receive', fileId: 'in')!.verifiedBytes, 70);
    expect(progress.getProgress(sessionId: 'receive', fileId: 'in'), 0);
    expect(progress.getProgress(sessionId: 'send', fileId: 'out'), 0.33);
    begin('new');
    verify('new', bytes: 10);
    verify('old');
    verify('new', bytes: 101);
    verify('new', total: 99);
    expect(progress.getVerification(sessionId: 'receive', fileId: 'in')!.verifiedBytes, 10);
    controller.onFileUploadProgress(HttpServerFileUploadProgressEvent(sessionId: 'receive', fileId: 'in', attemptId: 'old', progress: 0.9));
    expect(progress.getProgress(sessionId: 'receive', fileId: 'in'), 0);
    owner = 2;
    verify('new', bytes: 20);
    expect(progress.getVerification(sessionId: 'receive', fileId: 'in')!.verifiedBytes, 10);
    owner = 1;
    verify('new', active: false);
    expect(progress.getVerification(sessionId: 'receive', fileId: 'in'), isNull);
    verify('new');
    progress.setStatus(sessionId: 'receive', fileId: 'in', status: FileStatus.failed);
    verify('new');
    expect(progress.getVerification(sessionId: 'receive', fileId: 'in'), isNull);
    expect(progress.getStatus(sessionId: 'send', fileId: 'out'), FileStatus.sending);
  });
}
