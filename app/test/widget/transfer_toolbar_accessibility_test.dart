import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:refena_flutter/refena_flutter.dart';

import 'link_workspace_tags_test.dart' show WorkspaceServer;

void main() {
  testWidgets(
    'F6 reaches global shared-service tags from a closed-loop route; action semantics remain independent',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await LocaleSettings.setLocale(AppLocale.en);
      final key = GlobalKey<NavigatorState>();
      final tasks = [
        for (final direction in TransferDirection.values)
          TransferActivity(
            id: direction.name,
            direction: direction,
            phase: TransferPhase.waiting,
            peer: '${direction.name} peer',
            files: const [TransferActivityFile('one.txt', 10, 0)],
          ),
      ];
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            serverProvider.overrideWithNotifier((_) => WorkspaceServer()),
            networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
            transferActivityProvider.overrideWithBuilder((_) => tasks),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
              home: Scaffold(
                body: TextButton(autofocus: true, onPressed: () {}, child: const Text('Page action')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder button(String value) => find.descendant(of: find.byKey(ValueKey(value)), matching: find.byType(TextButton));
      final sharing = button('web-sharing-badge');
      final sending = button('transfer-badge-send');
      final receiving = button('transfer-badge-receive');
      expect(tester.getSemantics(sharing).getSemanticsData().label, t.transferNavigation.sharing);
      for (final action in [sharing, sending, receiving]) {
        expect(tester.getSemantics(action).getSemanticsData().flagsCollection.isButton, true);
        expect(tester.getSemantics(action).getSemanticsData().hasAction(SemanticsAction.tap), true);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(sharing).getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(sending).getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.widgetWithText(TextButton, 'Page action')).getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(sending).getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TransferActivityPanel), findsOneWidget);
      // Global nodes remain available even above a Navigator modal route.
      final receiveBadge = tester.getSemantics(receiving);
      expect(receiveBadge.getSemanticsData().label, contains(t.transferActivity.receive));
      receiveBadge.owner!.performAction(receiveBadge.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      final receiveChip = tester.getSemantics(find.byKey(const ValueKey('transfer-tab-receive')));
      receiveChip.owner!.performAction(receiveChip.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('transfer-tab-receive'))).getSemanticsData().flagsCollection.isSelected.toBoolOrNull(),
        true,
      );
      expect(find.text('receive peer'), findsOneWidget);
      final row = tester.getSemantics(find.byKey(const ValueKey('receive:receive')));
      row.owner!.performAction(row.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text('one.txt'), findsOneWidget);
      expect(find.text(t.transferActivity.back), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS}),
  );
}
