import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_history_control.dart';
import 'package:localsend_app/widget/api/api_history_control_button.dart';

const id = '11111111-1111-4111-8111-111111111111';
const page = {'instanceId': id, 'generation': 4, 'latest': 25};
void main() {
  test('clear target snapshots version and rejects incompatible results', () {
    final target = ApiHistoryClearTarget.fromPage(page);
    expect(target.body, {'instanceId': id, 'expectedGeneration': 4, 'throughSequence': 25});
    expect(target.validateResult({'instanceId': id, 'generation': 5, 'throughSequence': 25, 'removed': 20, 'latest': 28}), 20);
    for (final result in [
      <String, dynamic>{},
      {'instanceId': id, 'generation': 4, 'throughSequence': 25, 'removed': 20, 'latest': 28},
      {'instanceId': id, 'generation': 5, 'throughSequence': 25, 'removed': 201, 'latest': 28},
    ]) {
      expect(() => target.validateResult(result), throwsFormatException);
    }
  });
  test('malformed server versions are not sent as clear intent', () {
    for (final values in [
      <String, dynamic>{},
      {...page, 'generation': 0},
      {...page, 'latest': -1},
      {...page, 'instanceId': 'other'},
    ]) {
      expect(() => ApiHistoryClearTarget.fromPage(values), throwsFormatException);
    }
  });
  testWidgets('clear requires in-page confirmation and preserves captured watermark through refresh', (tester) async {
    final calls = <String>[];
    final busy = <bool>[];
    Map<String, Object>? payload;
    var refreshed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiHistoryControlButton(
            language: 'en',
            enabled: true,
            onBusy: busy.add,
            onRefreshed: (_) => refreshed = true,
            call: (operation, body) async {
              calls.add(operation);
              if (operation == 'listRequests') return page;
              payload = body;
              return {'instanceId': id, 'generation': 5, 'throughSequence': 25, 'removed': 20, 'latest': 28};
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('api-history-clear')));
    await tester.pumpAndSettle();
    expect(calls, ['listRequests']);
    expect(find.byKey(const ValueKey('api-history-clear-confirm')), findsOneWidget);
    await tester.tap(find.text('Clear observed records'));
    await tester.pumpAndSettle();
    expect(calls, ['listRequests', 'clearRequests', 'listRequests']);
    expect(payload, {'instanceId': id, 'expectedGeneration': 4, 'throughSequence': 25});
    expect(refreshed, true);
    expect(busy, [true, false]);
    expect(find.textContaining('Cleared 20 observed'), findsOneWidget);
  });
  testWidgets('cancel does not call mutation and backend failure never displays success', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiHistoryControlButton(
            language: 'zh-CN',
            enabled: true,
            onBusy: (_) {},
            call: (operation, body) async {
              calls.add(operation);
              if (operation == 'listRequests') return page;
              throw StateError('409 history_changed');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('api-history-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, ['listRequests']);
    await tester.tap(find.byKey(const ValueKey('api-history-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空已查看记录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-history-clear-failed')), findsOneWidget);
    expect(find.textContaining('已清空'), findsNothing);
    expect(calls, ['listRequests', 'listRequests', 'clearRequests']);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
  test('request control copy covers English Simplified and Traditional Chinese', () {
    expect(const ApiHistoryControlStrings('en').explanation, contains('requests.manage'));
    expect(const ApiHistoryControlStrings('zh-CN').explanation, contains('内存'));
    expect(const ApiHistoryControlStrings('zh-TW').explanation, contains('記憶體'));
    expect(const ApiHistoryControlStrings('zh-HK').explanation, const ApiHistoryControlStrings('zh-TW').explanation);
  });
}
