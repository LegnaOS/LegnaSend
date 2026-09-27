import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/api/server.dart' show SessionEndReasonV2;
import 'package:localsend_isolates/util/foreground_service.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

class _Fixture {
  final RefenaContainer container;
  ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('receive'), web: null);
  late final controller = ReceiveController(
    ServerUtils(
      refFunc: () => container,
      getState: () => state!,
      getStateOrNull: () => state,
      setState: (update) => state = update(state),
    ),
  );
  _Fixture() : container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
  FileTransferNotifier get progress => container.notifier(fileTransferProvider);
  void begin() {
    progress.setStatus(sessionId: 'receive', fileId: 'in', status: FileStatus.sending);
    TransferNotification.start(sessionId: 'receive', receiving: true);
  }

  Future<void> result({String? error}) => controller.onFileUploadResult(
    HttpServerFileUploadResultEvent(
      sessionId: 'receive',
      fileId: 'in',
      path: error == null ? '/destination/in.bin' : null,
      savedToGallery: false,
      error: error,
    ),
  );
  void upload() => controller.onFileUpload(
    HttpServerFileUploadEvent(
      sessionId: 'receive',
      fileId: 'in',
      file: rust.FileDto(id: 'in', fileName: 'in.bin', size: BigInt.from(100), fileType: 'application/octet-stream'),
    ),
  );
}

Future<void> _drain() async => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_foreground_task/methods');
  late _Fixture fixture;
  late List<String> calls;
  var running = false;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    running = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isRunningService':
          return running;
        case 'checkNotificationPermission':
          return 0;
        case 'startService':
          running = true;
        case 'stopService':
          running = false;
      }
      return null;
    });
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '$h:$m',
      ),
    );
    fixture = _Fixture();
  });
  tearDown(() async {
    fixture.controller.onServerStopped();
    TransferNotification.stop('receive');
    TransferNotification.stop('send');
    await _drain();
    fixture.container.disposeContainer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a retryable last-file failure retains receiving foreground membership until actual session end', () async {
    fixture.begin();
    await _drain();
    expect(ForegroundService.isRunning, true);
    await fixture.result(error: 'checksum mismatch');
    await _drain();
    expect(fixture.state!.session!.status, SessionStatus.finishedWithErrors);
    expect(ForegroundService.isRunning, true, reason: 'Rust still allows this session to retry');
    expect(calls.where((call) => call == 'stopService'), isEmpty);
    fixture.upload();
    await _drain();
    expect(fixture.state!.session!.status, SessionStatus.sending);
    expect(fixture.state!.session!.endTime, isNull);
    expect(fixture.progress.getProgress(sessionId: 'receive', fileId: 'in'), 0);
    expect(calls.where((call) => call == 'startService').length, 1, reason: 'Retry must not try to start a new Android service from background');
    fixture.controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.cancelled));
    await _drain();
    expect(ForegroundService.isRunning, false);
  });
  for (final endFirst in [true, false]) {
    for (final failed in [true, false]) {
      test('finished transport and ${failed ? 'failed' : 'successful'} result ordering endFirst=$endFirst', () async {
        TransferNotification.start(sessionId: 'send', receiving: false);
        fixture.begin();
        await _drain();
        final end = HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.finished);
        if (endFirst) {
          fixture.controller.onSessionEnd(end);
          expect(fixture.state!.session!.status, SessionStatus.sending, reason: 'Do not discard the pending child result');
          expect(fixture.progress.getStatus(sessionId: 'receive', fileId: 'in'), FileStatus.sending);
        }
        await fixture.result(error: failed ? 'post-processing failed after transport finished' : null);
        if (!endFirst) fixture.controller.onSessionEnd(end);
        fixture.controller.onSessionEnd(end);
        await _drain();
        expect(fixture.state!.session!.status, failed ? SessionStatus.finishedWithErrors : SessionStatus.finished);
        expect(fixture.state!.session!.files['in']!.path, failed ? isNull : '/destination/in.bin');
        expect(ForegroundService.isRunning, true, reason: 'Concurrent sending must retain foreground ownership');
        expect(calls.where((call) => call == 'stopService'), isEmpty);
        TransferNotification.stop('send');
        await _drain();
        expect(ForegroundService.isRunning, false, reason: 'Finished receiving must not leak its membership');
        final old = fixture.state!.session;
        fixture.upload();
        expect(fixture.state!.session, same(old), reason: 'A late upload cannot revive the finished transport');
      });
    }
  }

  for (final status in [SessionStatus.waiting, SessionStatus.sending, SessionStatus.finishedWithErrors]) {
    test('cancelled transport cleans only receive membership from ${status.name}', () async {
      TransferNotification.start(sessionId: 'send', receiving: false);
      fixture.state = fixture.state!.copyWith(session: incoming('receive', status: status));
      if (status != SessionStatus.waiting) fixture.begin();
      fixture.progress.setProgress(sessionId: 'send', fileId: 'out', progress: 0.42);
      await _drain();
      final event = HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.cancelled);
      fixture.controller.onSessionEnd(event);
      fixture.controller.onSessionEnd(event);
      await _drain();
      expect(fixture.state!.session!.status, SessionStatus.canceledBySender);
      expect(fixture.progress.getProgress(sessionId: 'send', fileId: 'out'), 0.42);
      expect(ForegroundService.isRunning, true);
      expect(calls.where((call) => call == 'stopService'), isEmpty);
      TransferNotification.stop('send');
      await _drain();
      expect(ForegroundService.isRunning, false);
      fixture.controller.closeSession(expectedSessionId: 'receive');
      fixture.controller.closeSession(expectedSessionId: 'receive');
      expect(fixture.state!.session, isNull);
      expect(fixture.progress.getData().containsKey('receive'), false);
      expect(fixture.progress.getProgress(sessionId: 'send', fileId: 'out'), 0.42);
    });
  }

  for (final status in [SessionStatus.waiting, SessionStatus.sending]) {
    test('aborted preparation releases optimistic acceptance notification from ${status.name}', () async {
      TransferNotification.start(sessionId: 'send', receiving: false);
      fixture.state = fixture.state!.copyWith(session: incoming('receive', status: status));
      if (status == SessionStatus.sending) fixture.begin();
      await _drain();
      final event = HttpServerPrepareUploadAbortedEvent(sessionId: 'receive');
      fixture.controller.onPrepareUploadAborted(event);
      fixture.controller.onPrepareUploadAborted(event);
      await _drain();
      expect(fixture.state!.session!.status, SessionStatus.canceledBySender);
      expect(ForegroundService.isRunning, true);
      TransferNotification.stop('send');
      await _drain();
      expect(ForegroundService.isRunning, false);
    });
  }

  test('stale terminal events and duplicate final results do not mutate a replacement', () async {
    fixture.begin();
    await _drain();
    fixture.controller.closeSession(expectedSessionId: 'receive');
    final replacement = incoming('next');
    fixture.state = fixture.state!.copyWith(session: replacement);
    fixture.progress.setStatus(sessionId: 'next', fileId: 'in', status: FileStatus.sending);
    fixture.progress.setProgress(sessionId: 'next', fileId: 'in', progress: 0.25);
    fixture.controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.finished));
    fixture.controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.cancelled));
    fixture.controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'receive'));
    await fixture.result();
    expect(fixture.state!.session, same(replacement));
    expect(fixture.progress.getProgress(sessionId: 'next', fileId: 'in'), 0.25);
    expect(fixture.progress.getData().containsKey('receive'), false);
  });
}
