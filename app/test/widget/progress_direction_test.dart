import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/util/native_resume_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

class TestServer extends ServerService {
  String? canceled;
  @override
  ServerState? init() => ServerState(alias: 'Self', port: 53317, https: true, session: incoming('same-id'), web: null);
  @override
  void cancelSession({String? expectedSessionId}) => canceled = expectedSessionId;
}

class TestSender extends SendNotifier {
  String? canceled;
  @override
  Map<String, SendSessionState> init() => {'same-id': outgoing('same-id')};
  @override
  void cancelSession(String sessionId) => canceled = sessionId;
}

class FixedSpeeds extends TransferSpeedNotifier {
  @override
  Map<String, int?> init() => {'send:same-id': 1500, 'receive:same-id': 2500};
}

void main() {
  for (final receiving in [false, true]) {
    testWidgets(
      'system Back hides progress without canceling either direction receiving=$receiving',
      (tester) async {
        final server = TestServer();
        final sender = TestSender();
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          RefenaScope(
            overrides: [
              transferSpeedProvider.overrideWithNotifier((_) => FixedSpeeds()),
              serverProvider.overrideWithNotifier((_) => server),
              sendProvider.overrideWithNotifier((_) => sender),
              settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: key,
                theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
                home: const Scaffold(body: Text('Home')),
              ),
            ),
          ),
        );
        unawaited(
          key.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => ProgressPage(showAppBar: true, closeSessionOnClose: true, sessionId: 'same-id', receiving: receiving),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
        expect(server.canceled, isNull);
        expect(sender.canceled, isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
    testWidgets('progress and cancel stay in direction receiving=$receiving even with equal IDs', (tester) async {
      final server = TestServer();
      final sender = TestSender();
      await LocaleSettings.setLocale(AppLocale.en);
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            transferSpeedProvider.overrideWithNotifier((_) => FixedSpeeds()),
            serverProvider.overrideWithNotifier((_) => server),
            sendProvider.overrideWithNotifier((_) => sender),
            settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
              home: ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: 'same-id', receiving: receiving),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(receiving ? t.progressPage.titleReceiving : t.progressPage.titleSending), findsOneWidget);
      expect(find.text(receiving ? 'in.bin' : 'out.bin'), findsOneWidget);
      expect(find.text(receiving ? 'out.bin' : 'in.bin'), findsNothing);
      expect(find.byKey(const ValueKey('progress-transfer-speed')), findsOneWidget);
      expect(find.text(receiving ? 'Current speed: 2.5 KB/s' : 'Current speed: 1.5 KB/s'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('native-resume-info')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(const NativeResumeStrings(AppLocale.en).explanation), findsOneWidget);
      expect(server.canceled, isNull);
      expect(sender.canceled, isNull);
      await tester.tap(find.text(t.general.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel).last);
      await tester.pumpAndSettle();
      expect(server.canceled, receiving ? 'same-id' : isNull);
      expect(sender.canceled, receiving ? isNull : 'same-id');
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
