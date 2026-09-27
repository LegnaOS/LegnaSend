import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';

class _Sender extends SendNotifier {
  _Sender(IsolateHttpUploadActionResult Function(IsolateHttpUploadFilesAction) upload, void Function(int) cancel)
    : super(uploadFiles: upload, cancelUpload: cancel);
  void seed(SendSessionState session) => state = {...state, session.sessionId: session};
}

void main() {
  late _Sender sender;
  late RefenaContainer container;
  late List<StreamController<HttpUploadEvent>> streams;
  late List<int> canceled;
  late FileTransferNotifier files;
  setUp(() {
    streams = [];
    canceled = [];
    sender = _Sender((_) {
      final stream = StreamController<HttpUploadEvent>();
      streams.add(stream);
      return IsolateHttpUploadActionResult(taskId: streams.length, events: stream.stream);
    }, canceled.add);
    container = RefenaContainer(overrides: [sendProvider.overrideWithNotifier((_) => sender)]);
    container.read(sendProvider);
    files = container.notifier(fileTransferProvider);
    sender.seed(outgoing('session').copyWith(background: false));
    files.setStatus(sessionId: 'session', fileId: 'out', status: FileStatus.queue);
  });
  tearDown(() async {
    for (final stream in streams) {
      if (!stream.isClosed) await stream.close();
    }
    container.disposeContainer();
  });
  Future<void> retry() => sender.sendFile(sessionId: 'session', file: container.read(sendProvider)['session']!.files['out']!, isRetry: false);
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  test('closing cancels actual upload and late events never resurrect removed progress', () async {
    final done = retry();
    await flush();
    sender.closeSession('session');
    streams.single.add(HttpUploadFileStartedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .8));
    await streams.single.close();
    await done;
    expect(canceled, [1]);
    expect(files.getData().containsKey('session'), false);
    expect(container.read(sendProvider), isEmpty);
  });
  test('old task callbacks and finish do not mutate replacement session using same ID', () async {
    final oldDone = retry();
    await flush();
    sender.closeSession('session');
    final replacement = outgoing('session').copyWith(background: false, remoteSessionId: 'replacement-remote');
    sender.seed(replacement);
    files.setStatus(sessionId: 'session', fileId: 'out', status: FileStatus.sending);
    streams.single.add(HttpUploadFileFailedEvent(fileId: 'out', error: 'stale error'));
    await streams.single.close();
    await oldDone;
    expect(container.read(sendProvider)['session'], same(replacement));
    expect(files.getStatus(sessionId: 'session', fileId: 'out'), FileStatus.sending);
  });
  test('duplicate prepared single-file dispatch is coalesced while already sending', () async {
    final first = retry();
    await flush();
    final second = retry();
    await flush();
    expect(streams, hasLength(1));
    streams.first.add(HttpUploadFileFinishedEvent(fileId: 'out'));
    for (final stream in streams) {
      await stream.close();
    }
    await Future.wait([first, second]);
  });
  test('premature stream close records failure rather than claiming successful delivery', () async {
    final done = retry();
    await flush();
    await streams.single.close();
    await done;
    expect(files.getStatus(sessionId: 'session', fileId: 'out'), FileStatus.failed);
    expect(container.read(sendProvider)['session']!.status, SessionStatus.finishedWithErrors);
    expect(container.read(sendProvider)['session']!.files['out']!.errorMessage, isNotEmpty);
  });
  test('first terminal file result wins and unknown file events are ignored', () async {
    final done = retry();
    await flush();
    streams.single.add(HttpUploadFileFinishedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'unknown', progress: .5));
    streams.single.add(HttpUploadFileFailedEvent(fileId: 'out', error: 'late failure'));
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .1));
    await streams.single.close();
    await done;
    expect(files.getStatus(sessionId: 'session', fileId: 'out'), FileStatus.finished);
    expect(files.getProgress(sessionId: 'session', fileId: 'out'), 1);
    expect(files.getData()['session']!.keys, ['out']);
  });
  test('cancelled retained transfer freezes partial bytes and ignores late success or failure', () async {
    final done = retry();
    await flush();
    streams.single.add(HttpUploadFileStartedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .35));
    await flush();
    sender.cancelSessionByReceiver('session');
    streams.single.add(HttpUploadFileFinishedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileFailedEvent(fileId: 'out', error: 'late failure'));
    await streams.single.close();
    await done;
    expect(container.read(sendProvider)['session']!.status, SessionStatus.canceledByReceiver);
    expect(files.getStatus(sessionId: 'session', fileId: 'out'), FileStatus.sending);
    expect(files.getProgress(sessionId: 'session', fileId: 'out'), .35);
  });
  test('late receiver cancel cannot rewrite an already terminal result', () async {
    final done = retry();
    await flush();
    streams.single.add(HttpUploadFileFinishedEvent(fileId: 'out'));
    await streams.single.close();
    await done;
    final terminal = container.read(sendProvider)['session'];
    expect(terminal!.status, SessionStatus.finished);
    sender.cancelSessionByReceiver('session');
    await sender.cancelSessionAndWait('session');
    expect(container.read(sendProvider)['session'], same(terminal));
    expect(canceled, isEmpty);
  });
  test('clearing sends preserves parallel receive progress in shared provider', () async {
    files.setStatus(sessionId: 'receive', fileId: 'incoming', status: FileStatus.sending);
    files.setProgress(sessionId: 'receive', fileId: 'incoming', progress: .4);
    final done = retry();
    await flush();
    sender.clearAllSessions();
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .8));
    await streams.single.close();
    await done;
    expect(files.getData().keys, ['receive']);
    expect(files.getProgress(sessionId: 'receive', fileId: 'incoming'), .4);
    expect(files.getStatus(sessionId: 'receive', fileId: 'incoming'), FileStatus.sending);
  });
  test('clear all cancels each active upload and late stream failures create no phantom entries', () async {
    final done = retry();
    await flush();
    sender.clearAllSessions();
    streams.single.addError(StateError('late transport failure'));
    await streams.single.close();
    await done;
    expect(canceled, [1]);
    expect(container.read(sendProvider), isEmpty);
    expect(files.getData(), isEmpty);
  });
}
