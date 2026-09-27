import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
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

  test('expiry preserves already published files and their paths in a partial session', () async {
    final session = fixture.state!.session!;
    fixture.state = fixture.state!.copyWith(
      session: session.copyWith(
        files: {
          ...session.files,
          'done': session.files['in']!.copyWith(file: transferFile('done', 100), desiredName: 'done.bin', path: '/published/done.bin'),
        },
      ),
    );
    fixture.progress.setStatus(sessionId: 'receive', fileId: 'in', status: FileStatus.queue);
    fixture.progress.setStatus(sessionId: 'receive', fileId: 'done', status: FileStatus.finished);
    fixture.controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.expired));
    expect(fixture.state!.session!.files['done']!.path, '/published/done.bin');
    expect(fixture.state!.session!.files['done']!.errorMessage, isNull);
    expect(fixture.progress.getStatus(sessionId: 'receive', fileId: 'done'), FileStatus.finished);
    expect(fixture.state!.session!.files['in']!.errorMessage, t.receivePage.idleExpired);
  });
  test('late old receipt does not release current receive or concurrent send notification', () async {
    TransferNotification.start(sessionId: 'send', receiving: false);
    fixture.begin();
    await _drain();
    final current = fixture.state!.session;
    await fixture.controller.onFileUploadResult(
      HttpServerFileUploadResultEvent(
        sessionId: 'older',
        fileId: 'in',
        path: '/published/old.bin',
        savedToGallery: false,
        error: null,
        receipt: HttpServerReceiveReceipt(
          receiptId: 'old',
          fileName: 'old.bin',
          fileType: FileType.other,
          fileSize: 100,
          senderAlias: 'Old peer',
          timestamp: DateTime.now().toUtc(),
        ),
      ),
    );
    expect(fixture.state!.session, same(current));
    TransferNotification.stop('send');
    await _drain();
    expect(ForegroundService.isRunning, true, reason: 'Current receiving still owns the foreground service');
    fixture.controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.expired));
    await _drain();
    expect(ForegroundService.isRunning, false);
  });
  for (final status in [SessionStatus.waiting, SessionStatus.sending, SessionStatus.finishedWithErrors]) {
    test('expired from ${status.name} marks incomplete files truthfully and retains send notification', () async {
      TransferNotification.start(sessionId: 'send', receiving: false);
      fixture.state = fixture.state!.copyWith(session: incoming('receive', status: status));
      if (status != SessionStatus.waiting) fixture.begin();
      fixture.progress.setProgress(sessionId: 'send', fileId: 'out', progress: 0.42);
      await _drain();
      final event = HttpServerSessionEndEvent(sessionId: 'receive', reason: SessionEndReasonV2.expired);
      fixture.controller.onSessionEnd(event);
      final terminal = fixture.state!.session;
      fixture.controller.onSessionEnd(event);
      expect(fixture.state!.session, same(terminal));
      expect(terminal!.status, SessionStatus.finishedWithErrors);
      expect(terminal.files['in']!.errorMessage, t.receivePage.idleExpired);
      expect(fixture.progress.getStatus(sessionId: 'receive', fileId: 'in'), FileStatus.failed);
      fixture.upload();
      await fixture.result(error: 'late failure');
      expect(fixture.state!.session, same(terminal));
      await _drain();
      expect(ForegroundService.isRunning, true);
      expect(fixture.progress.getProgress(sessionId: 'send', fileId: 'out'), 0.42);
      TransferNotification.stop('send');
      await _drain();
      expect(ForegroundService.isRunning, false);
    });
  }
}
