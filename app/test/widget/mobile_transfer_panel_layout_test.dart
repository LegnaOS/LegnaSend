import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'landscape large text details, rotation and back preserve transfers ${locale.name} scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(640, 320);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() => LocaleSettings.setLocale(locale));
          final tasks = [
            TransferActivity(
              id: 'outgoing',
              direction: TransferDirection.send,
              phase: TransferPhase.transferring,
              peer: 'Sending device',
              files: [
                const TransferActivityFile('outgoing.bin', 100, 25),
                for (var i = 1; i < 1000; i++) TransferActivityFile('outgoing-$i.bin', 100, 25),
              ],
            ),
            TransferActivity(
              id: 'incoming',
              direction: TransferDirection.receive,
              phase: TransferPhase.transferring,
              peer: 'Receiving device',
              files: [TransferActivityFile('incoming.bin', 100, 50)],
            ),
          ];
          late Ref ref;
          await tester.pumpWidget(
            RefenaScope(
              overrides: [transferActivityProvider.overrideWithBuilder((_) => tasks)],
              child: TranslationProvider(
                child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Builder(
                    builder: (context) {
                      ref = context.ref;
                      return Scaffold(
                        body: TextButton(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            useSafeArea: true,
                            builder: (_) => const TransferActivityPanel(initialDirection: TransferDirection.send, initialTaskKey: 'send:outgoing'),
                          ),
                          child: const Text('Open'),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(find.text('outgoing.bin'), 100);
          expect(find.text('outgoing.bin').hitTestable(), findsOneWidget);
          expect(find.text('outgoing-999.bin'), findsNothing); // File rows remain lazy.
          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('outgoing.bin'), findsOneWidget);
          tester.view.physicalSize = const Size(640, 320);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(find.text('Sending device'), 100);
          expect(find.text('Sending device').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Sending device'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.byKey(const ValueKey('transfer-tab-receive')), -100);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('transfer-tab-receive')));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('Receiving device'), 100);
          await tester.tap(find.text('Receiving device'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('incoming.bin'), 100);
          expect(find.text('incoming.bin').hitTestable(), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Open'), findsOneWidget);
          expect(ref.read(transferActivityProvider), tasks);
        },
        variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
      );
    }
  }
}
