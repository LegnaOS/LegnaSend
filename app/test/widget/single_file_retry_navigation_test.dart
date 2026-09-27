import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

class _Sender extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {'original': outgoing('original', status: SessionStatus.finishedWithErrors)};
}

class _Queue extends SendQueueNotifier {
  final calls = <String>[];
  @override
  String? retryFile({required String sessionId, required SendingFile file}) {
    calls.add('$sessionId:${file.file.id}');
    return 'actual-new-task';
  }
}

class _Server extends ServerService {
  @override
  ServerState? init() => null;
}

class _Speeds extends TransferSpeedNotifier {
  @override
  Map<String, int?> init() => {};
}

void main() {
  testWidgets(
    'failed file retry opens the actual new task and labels it as a new transfer',
    (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final queue = _Queue();
      final container = RefenaContainer(
        overrides: [
          sendProvider.overrideWithNotifier((_) => _Sender()),
          sendQueueProvider.overrideWithNotifier((_) => queue),
          serverProvider.overrideWithNotifier((_) => _Server()),
          transferSpeedProvider.overrideWithNotifier((_) => _Speeds()),
          settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
          transferActivityProvider.overrideWithBuilder(
            (_) => const [
              TransferActivity(
                id: 'actual-new-task',
                direction: TransferDirection.send,
                phase: TransferPhase.waiting,
                peer: 'Fresh retry task',
                files: [TransferActivityFile('only-selected-file.bin', 3, 0)],
              ),
            ],
          ),
        ],
      );
      container.notifier(fileTransferProvider).setStatus(sessionId: 'original', fileId: 'out', status: FileStatus.failed);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
              home: const ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: 'original'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t.sendQueue.singleFileRetryNewTask));
      await tester.pumpAndSettle();
      expect(queue.calls, ['original:out']);
      expect(find.byKey(const PageStorageKey('transfer-detail-send:actual-new-task')), findsOneWidget);
      expect(find.text('Fresh retry task'), findsOneWidget);
      expect(find.text('only-selected-file.bin'), findsOneWidget);
      expect(container.read(fileTransferProvider).getStatus(sessionId: 'original', fileId: 'out'), FileStatus.failed);
      await tester.pumpWidget(const SizedBox());
      container.disposeContainer();
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
}
