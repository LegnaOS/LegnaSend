import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/send/web/web_download_file.dart';
import 'package:localsend_app/model/state/send/web/web_download_session.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/controller/send_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/util/rust.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  late ServerState? state;
  late int epoch;
  late Completer<int> opened;
  late List<int> released;
  late List<(String?, int?)> targets;
  late int failures;
  late SendController controller;
  WebDownloadSession session(String id) => WebDownloadSession(sessionId: id, pending: true, ip: 'peer', deviceInfo: 'browser');
  ServerState makeState() => ServerState(
    alias: 'Host',
    port: 53317,
    https: false,
    session: null,
    web: WebShareDownload(
      pin: null,
      state: WebDownloadState(
        sessions: {'peer': session('peer')},
        files: {'file': WebDownloadFile(file: transferFile('file', 10), asset: null, path: 'content://source/file', bytes: null)},
        autoAccept: false,
      ),
    ),
  );
  HttpServerWebFileDownloadEvent event() =>
      HttpServerWebFileDownloadEvent(requestId: 'request', sessionId: 'peer', fileId: 'file', file: transferFile('file', 10).toRust());
  setUp(() {
    state = makeState();
    epoch = 1;
    opened = Completer<int>();
    released = [];
    targets = [];
    failures = 0;
    controller = SendController(
      ServerUtils(
        refFunc: () => throw StateError('Unexpected provider'),
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
        getListenerGeneration: () => epoch,
      ),
      resolveDescriptor: (_) => opened.future,
      releaseDescriptor: (fd) async => released.add(fd),
      downloadTarget: (_, path, fd) => targets.add((path, fd)),
      downloadFailed: (_) => failures++,
    );
  });
  test('late Android descriptor after listener restart is released without answering new listener', () async {
    final work = controller.onFileDownload(event());
    epoch++;
    state = makeState();
    controller.onServerStopped();
    opened.complete(41);
    await work;
    expect(released, [41]);
    expect(targets, isEmpty);
    expect(failures, 0);
  });
  test('same listener file replacement invalidates pending source and unblocks old request', () async {
    final work = controller.onFileDownload(event());
    state = makeState();
    opened.complete(42);
    await work;
    expect(released, [42]);
    expect(targets, isEmpty);
    expect(failures, 1);
  });
  test('ordinary share state updates preserve still-current source handoff', () async {
    final work = controller.onFileDownload(event());
    state = state!.copyWith(alias: 'Renamed');
    opened.complete(43);
    await work;
    expect(released, isEmpty);
    expect(targets, [(null, 43)]);
    expect(failures, 0);
  });
  test('handoff failure releases exactly one acquired descriptor and unblocks request', () async {
    controller = SendController(
      controller.server,
      resolveDescriptor: (_) => opened.future,
      releaseDescriptor: (fd) async => released.add(fd),
      downloadTarget: (_, path, fd) => throw StateError('isolate unavailable'),
      downloadFailed: (_) => failures++,
    );
    final work = controller.onFileDownload(event());
    opened.complete(44);
    await work;
    expect(released, [44]);
    expect(failures, 1);
  });
  test('resolver failure after stop does not issue a command to a new listener', () async {
    final work = controller.onFileDownload(event());
    state = null;
    epoch++;
    controller.onServerStopped();
    opened.completeError(StateError('provider closed'));
    await work;
    expect(released, isEmpty);
    expect(targets, isEmpty);
    expect(failures, 0);
  });
  test('late approval finally cannot clear newer same-id decision guard', () async {
    final old = Completer<void>(), fresh = Completer<void>();
    var decisions = 0;
    controller = SendController(controller.server, sendDecision: (_, _) => ++decisions == 1 ? old.future : fresh.future);
    final before = controller.acceptRequest('peer');
    epoch++;
    state = makeState();
    controller.onServerStopped();
    final after = controller.acceptRequest('peer');
    old.complete();
    await before;
    await controller.acceptRequest('peer');
    expect(decisions, 2);
    fresh.complete();
    await after;
    expect(state!.webDownloadState!.sessions['peer']!.pending, false);
  });
  test('duplicate prepare event preserves existing pending/accepted session identity', () async {
    controller = SendController(controller.server, sendDecision: (_, _) async {});
    final original = state!.webDownloadState!.sessions['peer'];
    controller.onPrepareDownload(HttpServerWebPrepareDownloadEvent(sessionId: 'peer', ip: 'other', userAgent: null));
    expect(state!.webDownloadState!.sessions['peer'], same(original));
    await controller.acceptRequest('peer');
    final accepted = state!.webDownloadState!.sessions['peer'];
    controller.onPrepareDownload(HttpServerWebPrepareDownloadEvent(sessionId: 'peer', ip: 'other', userAgent: null));
    expect(state!.webDownloadState!.sessions['peer'], same(accepted));
    expect(accepted!.pending, false);
  });
}
