import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/util/receive_session_lookup.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:test/test.dart';

ReceiveSessionState receiveSession(String id, SessionStatus status) => ReceiveSessionState(
  sessionId: id,
  status: status,
  sender: Device.empty,
  senderAlias: 'Sender',
  files: {},
  startTime: null,
  endTime: null,
  destinationDirectory: '/destination',
  cacheDirectory: '/cache',
  saveToGallery: false,
  createdDirectories: {},
);

void main() {
  test('progress lookup only selects the requested receive session', () {
    final session = receiveSession('incoming', SessionStatus.sending);
    expect(receiveSessionForId(session, 'outgoing'), isNull);
    expect(receiveSessionForId(session, 'old-incoming'), isNull);
    expect(receiveSessionForId(session, 'incoming'), same(session));
    expect(receiveSessionForId(null, 'incoming'), isNull);
  });

  test('stale accept, decline, close, cancel and options never touch the new request', () async {
    for (final status in SessionStatus.values) {
      final state = ServerState(alias: 'Self', port: 53317, https: true, session: receiveSession('new', status), web: null);
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => throw StateError('A stale callback accessed providers'),
          getState: () => state,
          getStateOrNull: () => state,
          setState: (_) => fail('A stale callback mutated the new receive session'),
        ),
      );
      await controller.acceptFileRequest({'file': 'a.txt'}, expectedSessionId: 'old');
      controller.declineFileRequest(expectedSessionId: 'old');
      controller.cancelSession(expectedSessionId: 'old');
      controller.closeSession(expectedSessionId: 'old');
      controller.setSessionDestinationDir('/wrong', expectedSessionId: 'old');
      controller.setSessionSaveToGallery(true, expectedSessionId: 'old');
    }
  });

  test('destination changes apply only to the matching session', () {
    ServerState? state = ServerState(alias: 'Self', port: 53317, https: true, session: receiveSession('new', SessionStatus.waiting), web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => throw StateError('Unexpected provider access'),
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
    );
    controller.setSessionDestinationDir('/chosen', expectedSessionId: 'new');
    controller.setSessionSaveToGallery(true, expectedSessionId: 'new');
    expect(state!.session!.destinationDirectory, '/chosen');
    expect(state!.session!.saveToGallery, isTrue);
    for (final location in [
      r'D:\资料\Downloads',
      r'\\nas\downloads\用户',
      r'\\?\C:\long\Downloads',
      '/tmp/literal\\part ',
      'content://documents/tree/primary%3ADownload%2F资料',
      '/sandbox/Documents/Downloads',
    ]) {
      controller.setSessionDestinationDir(location, expectedSessionId: 'new');
      expect(state!.session!.destinationDirectory, location);
    }
  });
}
