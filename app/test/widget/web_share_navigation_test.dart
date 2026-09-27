import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

class SharingServer extends ServerService {
  int stopCalls = 0;
  int? requestedGeneration;
  int epoch = 7;
  @override
  int get generation => epoch;
  @override
  ServerState? init() => ServerState(alias: 'Self', port: 53318, https: false, session: incoming('incoming'), web: const WebShareUpload(pin: null));
  @override
  Future<bool> stopWebShare({required int expectedGeneration}) async {
    requestedGeneration = expectedGeneration;
    if (expectedGeneration != epoch) return false;
    stopCalls++;
    return true;
  }
}

class QuietNetwork extends LocalIpService {
  QuietNetwork(super.settings) : super(monitor: false);
  @override
  NetworkState init() => const NetworkState(localIps: [], initialized: true);
}

void main() {
  testWidgets(
    'Back hides a pending receive decision without declining or clearing file choices',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      var decisions = 0;
      late Ref ref;
      final request = incoming('pending', status: SessionStatus.waiting);
      final vm = ViewProvider(
        (_) => ReceivePageVm(
          status: request.status,
          sessionId: request.sessionId,
          sender: request.sender,
          showSenderInfo: false,
          files: request.files.values.map((f) => f.file).toList(),
          message: null,
          onAccept: () => decisions++,
          onDecline: () => decisions++,
          onClose: () => decisions++,
        ),
      );
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
            favoritesProvider.overrideWithNotifier((_) => FavoritesService(MockPersistenceService())),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
              builder: (context, child) {
                ref = context.ref;
                return child!;
              },
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      ref.notifier(selectedReceivingFilesProvider).setFiles(request.files.values.map((f) => f.file).toList());
      unawaited(key.currentState!.push(MaterialPageRoute<void>(builder: (_) => ReceivePage(vm))));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(decisions, 0);
      expect(ref.read(selectedReceivingFilesProvider), {'in': 'in.bin'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );

  testWidgets(
    'Back and reopen preserve web service; only confirmed Stop invokes generation-guarded shutdown',
    (tester) async {
      final server = SharingServer();
      final settings = SettingsService(MockPersistenceService());
      final key = GlobalKey<NavigatorState>();
      await LocaleSettings.setLocale(AppLocale.en);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            serverProvider.overrideWithNotifier((_) => server),
            settingsProvider.overrideWithNotifier((_) => settings),
            localIpProvider.overrideWithNotifier((_) => QuietNetwork(settings)),
            networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
            transferActivityProvider.overrideWithBuilder((_) => []),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
              builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('web-sharing-badge')), findsOneWidget);
      unawaited(key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const WebSharePage(resume: true))));
      await tester.pumpAndSettle();
      expect(find.text(t.transferNavigation.keepSharing), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(server.stopCalls, 0);
      expect(server.generation, 7);
      expect(server.state?.session?.sessionId, 'incoming');
      await tester.tap(find.byKey(const ValueKey('web-sharing-badge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stop-web-sharing')));
      await tester.pumpAndSettle();
      expect(find.text(t.transferNavigation.stopBody), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(server.stopCalls, 0);
      // A confirmation opened for the old service never stops its replacement.
      await tester.tap(find.byKey(const ValueKey('stop-web-sharing')));
      await tester.pumpAndSettle();
      server.epoch++;
      await tester.tap(find.text(t.general.confirm));
      await tester.pumpAndSettle();
      expect(server.requestedGeneration, 7);
      expect(server.stopCalls, 0);
      await tester.tap(find.byKey(const ValueKey('web-sharing-badge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stop-web-sharing')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.confirm));
      await tester.pumpAndSettle();
      expect(server.stopCalls, 1);
      expect(server.requestedGeneration, 8);
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
}
