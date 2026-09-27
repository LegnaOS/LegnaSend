import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/widget/network_address_tags.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';
import 'link_workspace_tags_test.dart' show WorkspaceServer, TagNetwork, network;

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets(
      'each multi-interface share action exposes an independently named button ${locale.languageTag}',
      (tester) async {
        final semantics = tester.ensureSemantics();

        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        final settings = SettingsService(MockPersistenceService());
        await tester.pumpWidget(
          RefenaScope(
            overrides: [
              serverProvider.overrideWithNotifier((_) => WorkspaceServer()),
              settingsProvider.overrideWithNotifier((_) => settings),
              localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
              networkEnvironmentProvider.overrideWithBuilder((_) => network),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                initialRoute: '/share',
                routes: {
                  '/': (_) => const Scaffold(body: Text('Original page')),
                  '/share': (_) => const WebSharePage(resume: true),
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final url = 'http://192.168.1.4:53318/share';
        for (var index = 0; index < network.addresses.length; index++) {
          final address = network.addresses[index];
          final data = tester.getSemantics(find.byType(NetworkAddressTags).at(index)).getSemanticsData();
          expect(data.label, contains(address.interfaceName));
          expect(data.label, contains(address.cidr!));
          expect(data.flagsCollection.isButton, false);
        }
        for (final pair in [(Icons.content_copy, t.general.copy), (Icons.qr_code, t.dialogs.qr.title), (Icons.tv, t.dialogs.zoom.title)]) {
          final action = find.byIcon(pair.$1).first;
          final data = tester.getSemantics(find.ancestor(of: action, matching: find.byType(IconButton)).first).getSemanticsData();
          expect(data.label, contains(pair.$2));
          expect(data.label, contains(url));
          expect(data.hasAction(SemanticsAction.tap), true);
          expect(data.flagsCollection.isButton, true);
        }
        for (final pair in [(Icons.stop_circle_outlined, t.transferNavigation.stopSharing), (Icons.refresh, t.networkLabels.refresh)]) {
          final button = find.ancestor(of: find.byIcon(pair.$1), matching: find.byType(IconButton));
          final data = tester.getSemantics(button).getSemanticsData();
          expect(data.label, pair.$2);
          expect(data.hasAction(SemanticsAction.tap), true);
        }
        final back = find.ancestor(of: find.byIcon(Icons.arrow_back), matching: find.byType(IconButton));
        final backNode = tester.getSemantics(back);
        expect(backNode.getSemanticsData().label, isNotEmpty);
        backNode.owner!.performAction(backNode.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.text('Original page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
      variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
}
