import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/session_status.dart';
import '../../fixtures/transfer_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('server preparation abort cancels optimistic acceptance but never a replacement session', () {
    ServerState? state = ServerState(alias: 'Self', port: 1, https: false, session: incoming('pending'), web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => throw StateError('No provider needed'),
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
    );
    controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'old'));
    expect(state!.session!.status, SessionStatus.sending);
    controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'pending'));
    expect(state!.session!.status, SessionStatus.canceledBySender);
    final end = state!.session!.endTime;
    controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'pending'));
    expect(state!.session!.endTime, end);
  });
}
