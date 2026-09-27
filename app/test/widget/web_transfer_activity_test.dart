import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/util/web_transfer_activity_strings.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:refena_flutter/refena_flutter.dart';

class RecordingWebActivities extends WebTransferActivityNotifier {
  final canceled = <String>[];
  @override
  Future<bool> cancel(String id, {int? expectedGeneration}) async {
    canceled.add(id);
    return true;
  }
}

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('browser/native narrow task panel isolation and hide ${locale.name}', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final recorder = RecordingWebActivities();
      late Ref ref;
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            webTransferActivityProvider.overrideWithNotifier((_) => recorder),
            transferActivityProvider.overrideWithBuilder(
              (ref) => [
                ...ref.watch(webTransferActivityProvider),
                const TransferActivity(
                  id: 'incoming',
                  direction: TransferDirection.receive,
                  phase: TransferPhase.transferring,
                  peer: 'Native peer',
                  files: [TransferActivityFile('native.bin', 100, 40)],
                ),
              ],
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  ref = context.ref;
                  return Scaffold(
                    body: TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => const TransferActivityPanel(initialDirection: TransferDirection.send),
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
      recorder.apply(
        jsonEncode([
          {'id': 'response', 'peer': 'Browser', 'name': 'data.zip', 'phase': 'transferring', 'total': null, 'transferred': 5000},
        ]),
        generation: 1,
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('webResponse:send:response')));
      await tester.pump();
      final labels = WebTransferActivityStrings(locale);
      expect(find.text(labels.detail), findsNothing);
      await tester.tap(find.byTooltip(labels.help));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(labels.detail), findsOneWidget);
      await tester.tap(find.text(t.general.close));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(find.text('data.zip'), 150, scrollable: find.byType(Scrollable).last);
      expect(find.text('data.zip'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-tab-receive')));
      await tester.pump();
      expect(find.text('Native peer'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-tab-send')));
      await tester.pump();
      expect(find.text('data.zip'), findsOneWidget);
      await tester.ensureVisible(find.text(t.general.cancel));
      await tester.pump();
      // Cancellation is explicit and scoped to this response, never a native
      // session or the hosting web share. Continue dismisses the confirmation.
      await tester.tap(find.text(t.general.cancel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(t.dialogs.cancelSession.title), findsOneWidget);
      await tester.tap(find.text(t.general.continueStr));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(recorder.canceled, isEmpty);
      await tester.tap(find.text(t.general.cancel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ElevatedButton, t.general.cancel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(recorder.canceled, ['response']);
      await tester.tap(find.byTooltip(t.transferNavigation.hide));
      await tester.pumpAndSettle();
      expect(ref.read(webTransferActivityProvider).single.active, true);
      expect(recorder.canceled, ['response']);
      expect(ref.read(transferActivityProvider).last.id, 'incoming');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
