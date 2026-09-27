import 'dart:async';

import 'package:flutter/foundation.dart';
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
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart' as wakelock;
// The platform interface is deliberately injected instead of invoking a device plugin.
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

class _Wake extends WakelockPlusPlatformInterface {
  bool active = false;
  final calls = <bool>[];
  @override
  Future<bool> get enabled async => active;
  @override
  Future<void> toggle({required bool enable}) async {
    active = enable;
    calls.add(enable);
  }
}

class _Sender extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {'send': outgoing('send')};
  void status(SessionStatus status) => state = {'send': outgoing('send', status: status)};
}

class _Server extends ServerService {
  @override
  ServerState? init() => ServerState(alias: 'Self', port: 53317, https: false, session: incoming('receive'), web: null);
}

class _Speeds extends TransferSpeedNotifier {
  @override
  Map<String, int?> init() => {};
}

Future<void> _mount(WidgetTester tester, GlobalKey<NavigatorState> key, _Sender sender) => tester.pumpWidget(
  RefenaScope(
    overrides: [
      sendProvider.overrideWithNotifier((_) => sender),
      serverProvider.overrideWithNotifier((_) => _Server()),
      transferSpeedProvider.overrideWithNotifier((_) => _Speeds()),
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
void _push(GlobalKey<NavigatorState> key, bool receiving) {
  unawaited(
    key.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ProgressPage(
          showAppBar: true,
          closeSessionOnClose: false,
          sessionId: receiving ? 'receive' : 'send',
          receiving: receiving,
        ),
      ),
    ),
  );
}

void main() {
  late WakelockPlusPlatformInterface previous;
  late _Wake wake;
  setUp(() {
    previous = wakelock.wakelockPlusPlatformInstance;
    wake = _Wake();
    wakelock.wakelockPlusPlatformInstance = wake;
  });
  tearDown(() => wakelock.wakelockPlusPlatformInstance = previous);
  testWidgets(
    'closing one direction keeps the other page lease; last close releases once',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      await _mount(tester, key, _Sender());
      _push(key, false);
      await tester.pumpAndSettle();
      _push(key, true);
      await tester.pumpAndSettle();
      await tester.pump();
      final supported = defaultTargetPlatform != TargetPlatform.android;
      expect(wake.active, supported);
      expect(wake.calls, supported ? [true] : <bool>[]);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump();
      expect(wake.active, supported);
      expect(find.text(t.progressPage.titleSending), findsOneWidget);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump();
      expect(wake.active, false);
      expect(wake.calls, supported ? [true, false] : <bool>[]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );

  testWidgets('completion releases and a same-attempt file retry reacquires without polling', (tester) async {
    final key = GlobalKey<NavigatorState>(), sender = _Sender();
    await _mount(tester, key, sender);
    _push(key, false);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(wake.active, true);
    sender.status(SessionStatus.finishedWithErrors);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(wake.active, false);
    sender.status(SessionStatus.sending);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(wake.active, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(wake.calls, [true, false, true, false]);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
