import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/send/web/web_download_session.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/controller/send_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_isolates/isolate.dart';

void main() {
  late ServerState? state;
  late SendController controller;
  late Completer<void> decision;
  late int calls;
  WebDownloadSession session(String id) => WebDownloadSession(sessionId: id, pending: true, ip: 'same-ip', deviceInfo: 'Browser');
  setUp(() {
    calls = 0;
    decision = Completer<void>();
    state = ServerState(
      alias: 'Self',
      port: 53317,
      https: false,
      session: null,
      web: WebShareDownload(
        pin: null,
        state: WebDownloadState(sessions: {'old': session('old'), 'new': session('new')}, files: {}, autoAccept: false),
      ),
    );
    controller = SendController(
      ServerUtils(
        refFunc: () => throw StateError('Unexpected provider call'),
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
      sendDecision: (_, _) {
        calls++;
        return decision.future;
      },
    );
  });
  test('approve only becomes accepted after actual worker acknowledgement', () async {
    final pending = controller.acceptRequest('old');
    expect(state!.webDownloadState!.sessions['old']!.pending, true);
    await controller.acceptRequest('old');
    expect(calls, 1);
    decision.complete();
    await pending;
    expect(state!.webDownloadState!.sessions['old']!.pending, false);
    expect(state!.webDownloadState!.sessions['new']!.pending, true);
  });
  test('failed response removes only expired card rather than displaying accepted', () async {
    final pending = controller.acceptRequest('old');
    decision.completeError(StateError('already ended'));
    await pending;
    expect(state!.webDownloadState!.sessions.keys, ['new']);
  });
  test('abort before acknowledgement cannot recreate an expired card', () async {
    final pending = controller.acceptRequest('old');
    controller.onPrepareDownloadAborted(HttpServerWebPrepareDownloadAbortedEvent(sessionId: 'old'));
    decision.complete();
    await pending;
    expect(state!.webDownloadState!.sessions.keys, ['new']);
  });
  test('repeated stale abort preserves same-IP new session and closed service', () {
    for (var i = 0; i < 10; i++) {
      controller.onPrepareDownloadAborted(HttpServerWebPrepareDownloadAbortedEvent(sessionId: 'old'));
    }
    expect(state!.webDownloadState!.sessions.keys, ['new']);
    state = null;
    controller.onPrepareDownloadAborted(HttpServerWebPrepareDownloadAbortedEvent(sessionId: 'new'));
    expect(state, isNull);
  });
  test('decline is deduplicated and removes request after acknowledgement', () async {
    final pending = controller.declineRequest('old');
    await controller.acceptRequest('old');
    expect(calls, 1);
    decision.complete();
    await pending;
    expect(state!.webDownloadState!.sessions.keys, ['new']);
  });
  test('closed share stays closed after late successful decision', () async {
    final pending = controller.acceptRequest('old');
    state = state!.copyWith(web: null);
    decision.complete();
    await pending;
    expect(state!.web, isNull);
  });
}
