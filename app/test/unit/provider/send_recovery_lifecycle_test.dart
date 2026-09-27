import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';

class _Sender extends SendNotifier {
  _Sender(IsolateHttpUploadActionResult Function(IsolateHttpUploadFilesAction) upload) : super(uploadFiles: upload, cancelUpload: (_) {});
  void seed(SendSessionState session) => state = {...state, session.sessionId: session};
}

void main() {
  late _Sender sender;
  late RefenaContainer container;
  late List<StreamController<HttpUploadEvent>> streams;
  late FileTransferNotifier files;
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  setUp(() {
    streams = [];
    sender = _Sender((_) {
      final stream = StreamController<HttpUploadEvent>();
      streams.add(stream);
      return IsolateHttpUploadActionResult(taskId: streams.length, events: stream.stream);
    });
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
  Future<void> start() => sender.sendFile(sessionId: 'session', file: container.read(sendProvider)['session']!.files['out']!, isRetry: false);
  TransferActivity activity() => collectTransferActivities(jobs: [], sends: container.read(sendProvider), receive: null, progress: files).single;

  test('real sender waiting transitions never become verification or transmitted bytes', () async {
    final done = start();
    await flush();
    streams.single.add(HttpUploadFileStartedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileVerificationEvent(fileId: 'out', verifiedBytes: 80, totalBytes: 100));
    streams.single.add(HttpUploadFileRecoveryEvent(fileId: 'out', waiting: true, attempt: 1, retryAfterMs: 1000));
    await flush();
    expect(files.getRecovery(sessionId: 'session', fileId: 'out')!.waiting, true);
    expect(activity().recovery!.waiting, true);
    expect(activity().transferredBytes, 0);
    expect(activity().verification!.verifiedBytes, 80);
    streams.single.add(HttpUploadFileRecoveryEvent(fileId: 'out', waiting: false, attempt: 1, retryAfterMs: 0));
    await flush();
    expect(activity().recovery, isNull);
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .4));
    await flush();
    expect(activity().verification, isNull);
    expect(activity().transferredBytes, 40);
    streams.single.add(HttpUploadFileFinishedEvent(fileId: 'out'));
    await streams.single.close();
    await done;
    expect(activity().recovery, isNull);
    expect(activity().phase, TransferPhase.succeeded);
  });

  for (final kind in UploadRecoveryFailureKind.values) {
    test('typed ${kind.name} is retained in per-file and task UI without parsing error text', () async {
      final done = start();
      await flush();
      streams.single.add(HttpUploadFileStartedEvent(fileId: 'out'));
      streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .4));
      streams.single.add(
        HttpUploadFileFailedEvent(
          fileId: 'out',
          error: '<untrusted source-ended body>',
          recovery: UploadRecoveryFailure(
            kind: kind,
            retention: UploadRecoveryRetention.unknown,
            status: 403,
          ),
        ),
      );
      await streams.single.close();
      await done;
      final session = container.read(sendProvider)['session']!;
      expect(session.status, SessionStatus.finishedWithErrors);
      expect(session.files['out']!.retainedAfterInterruption, false);
      expect(session.files['out']!.errorMessage, isNot(contains('untrusted')));
      expect(files.getRecovery(sessionId: 'session', fileId: 'out')!.failure!.kind, kind);
      expect(activity().recovery!.failure!.kind, kind);
      expect(activity().transferredBytes, 40);
      expect(activity().phase, TransferPhase.failed);
      expect(activity().verification, isNull);
    });
  }

  test('stale old-task recovery never mutates same-ID replacement or the receive direction', () async {
    final done = start();
    await flush();
    sender.closeSession('session');
    final replacement = outgoing('session').copyWith(background: false, remoteSessionId: 'new-remote');
    sender.seed(replacement);
    files.setStatus(sessionId: 'session', fileId: 'out', status: FileStatus.sending);
    files.beginVerificationAttempt(sessionId: 'session', fileId: 'out', attemptId: 'new');
    files.setStatus(sessionId: 'receiving', fileId: 'in', status: FileStatus.sending);
    files.setProgress(sessionId: 'receiving', fileId: 'in', progress: .6);
    streams.single.add(HttpUploadFileRecoveryEvent(fileId: 'out', waiting: true, attempt: 1, retryAfterMs: 1000));
    streams.single.add(
      HttpUploadFileFailedEvent(
        fileId: 'out',
        error: 'late',
        recovery: const UploadRecoveryFailure(
          kind: UploadRecoveryFailureKind.sourceChanged,
          retention: UploadRecoveryRetention.notRetained,
        ),
      ),
    );
    await streams.single.close();
    await done;
    expect(container.read(sendProvider)['session'], same(replacement));
    expect(files.getRecovery(sessionId: 'session', fileId: 'out'), isNull);
    expect(files.getProgress(sessionId: 'receiving', fileId: 'in'), .6);
    expect(files.getStatus(sessionId: 'receiving', fileId: 'in'), FileStatus.sending);
  });
  test('cancellation clears waiting and verification without changing last transmitted bytes', () async {
    final done = start();
    await flush();
    streams.single.add(HttpUploadFileStartedEvent(fileId: 'out'));
    streams.single.add(HttpUploadFileProgressEvent(fileId: 'out', progress: .4));
    streams.single.add(HttpUploadFileVerificationEvent(fileId: 'out', verifiedBytes: 80, totalBytes: 100));
    streams.single.add(HttpUploadFileRecoveryEvent(fileId: 'out', waiting: true, attempt: 1, retryAfterMs: 1000));
    await flush();
    sender.cancelSessionByReceiver('session');
    expect(activity().phase, TransferPhase.canceled);
    expect(activity().recovery, isNull);
    expect(activity().verification, isNull);
    expect(activity().transferredBytes, 40);
    streams.single.add(HttpUploadFileRecoveryEvent(fileId: 'out', waiting: true, attempt: 2, retryAfterMs: 2000));
    await streams.single.close();
    await done;
    expect(activity().recovery, isNull);
  });

  test('provider rejects invalid phase and old attempt, clearing completed and removed recovery only', () {
    files.setStatus(sessionId: 'session', fileId: 'out', status: FileStatus.sending);
    files.beginVerificationAttempt(sessionId: 'session', fileId: 'out', attemptId: 'current');
    bool set(String attempt, UploadRecoveryState value) => files.setRecovery(sessionId: 'session', fileId: 'out', attemptId: attempt, value: value);
    expect(set('old', const UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 1000)), false);
    expect(set('current', const UploadRecoveryState.waiting(attempt: 0, retryAfterMs: 1000)), false);
    expect(set('current', const UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 1000)), true);
    files.setStatus(sessionId: 'session', fileId: 'out', status: FileStatus.finished);
    expect(files.getRecovery(sessionId: 'session', fileId: 'out'), isNull);
    expect(set('current', const UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 1000)), false);
    files.removeSession('session');
    expect(files.recoveryForSession('session'), isNull);
  });
}
