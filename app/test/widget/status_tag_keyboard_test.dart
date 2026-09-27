import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/share_link_actions.dart';
import 'package:localsend_app/widget/status_tag.dart';

void main() {
  for (final width in [390.0, 1040.0]) {
    testWidgets(
      'tags and link actions have focus, names and keyboard activation at width=$width',
      (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await LocaleSettings.setLocale(AppLocale.en);
        final calls = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  StatusTag(label: 'Sharing', semanticsLabel: 'Open link workspace', onTap: () => calls.add('tag')),
                  ShareLinkActions(
                    url: 'http://192.168.1.4:53318/share',
                    onCopy: () => calls.add('copy'),
                    onQr: () => calls.add('qr'),
                    onZoom: () => calls.add('zoom'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final buttons = [find.byType(TextButton), ...List.generate(3, (i) => find.byType(IconButton).at(i))];
        final labels = ['Open link workspace', t.general.copy, t.dialogs.qr.title, t.dialogs.zoom.title];
        for (var index = 0; index < buttons.length; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          final node = tester.getSemantics(buttons[index]);
          expect(node.getSemanticsData().label, contains(labels[index]));
          expect(node.getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), true, reason: 'Tab step $index');
          expect(node.getSemanticsData().flagsCollection.isButton, true);
          await tester.sendKeyEvent(index.isEven ? LogicalKeyboardKey.enter : LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(calls.length, index + 1);
          if (index > 0) {
            expect(tester.getSize(buttons[index]).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(buttons[index]).height, greaterThanOrEqualTo(48));
          }
        }
        expect(calls, ['tag', 'copy', 'qr', 'zoom']);
        semantics.dispose();
      },
      variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
}
