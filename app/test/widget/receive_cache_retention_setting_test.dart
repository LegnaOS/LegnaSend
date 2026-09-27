import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:localsend_app/widget/receive_cache_retention_setting.dart';

void main() {
  for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    testWidgets('$locale narrow retention settings handles selection and errors', (tester) async {
      tester.view.physicalSize = const Size(360, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var saved = -2, actual = -2, fail = false;
      final controller = ReceiveCacheRetentionController(
        readSaved: () => saved,
        save: (d) async => saved = d,
        configure: (d) async {
          if (fail) throw StateError('offline');
          return actual = d;
        },
        readActual: () async => actual,
        allowAutomatic: (_) {},
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final strings = ReceiveCacheRetentionStrings(locale);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: SingleChildScrollView(
                child: ReceiveCacheRetentionSetting(controller: controller, locale: locale),
              ),
            ),
          ),
        ),
      );
      expect(find.text(strings.actual(-2)), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.policy(-1)).last);
      await tester.pumpAndSettle();
      expect(saved, -1);
      expect(find.text(strings.actual(-1)), findsNothing);
      fail = true;
      await controller.change(7);
      await tester.pumpAndSettle();
      expect(find.text(strings.failure('apply')), findsOneWidget);
      expect(find.text(strings.actual(-1)), findsOneWidget);
      expect(tester.takeException(), isNull);
      fail = false;
      await tester.ensureVisible(find.text(strings.retry));
      await tester.tap(find.text(strings.retry));
      await tester.pumpAndSettle();
      expect(find.text(strings.failure('apply')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
