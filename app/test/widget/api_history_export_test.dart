import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_history_export.dart';
import 'package:localsend_app/widget/api/api_history_export_button.dart';

void main() {
  testWidgets('history confirmation cancellation does not save and CSV saves bounded data', (tester) async {
    var writes = 0;
    Uint8List? output;
    final busy = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: ApiHistoryExportButton(
            language: 'zh-CN',
            enabled: true,
            load: () async => const ApiHistorySnapshot('id', 0, false, []),
            onBusy: busy.add,
            save: (bytes, name) async {
              writes++;
              output = bytes;
              expect(name, endsWith('.csv'));
              return 'saved';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('api-history-export')));
    await tester.pumpAndSettle();
    expect(find.text('导出脱敏请求记录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(busy, [true, false]);
    await tester.tap(find.byKey(const ValueKey('api-history-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSV'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(output, isNotEmpty);
    expect(find.text('记录已保存'), findsOneWidget);
  });
  testWidgets('failed authorization never opens file save and late completion leaves closed page untouched', (tester) async {
    var writes = 0;
    final pending = Completer<ApiHistorySnapshot>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: ApiHistoryExportButton(
            language: 'en',
            enabled: true,
            load: () => Future.error(StateError('private')),
            onBusy: (_) {},
            save: (_, _) async {
              writes++;
              return 'saved';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('api-history-export')));
    await tester.pumpAndSettle();
    expect(find.text('Export failed'), findsOneWidget);
    expect(writes, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: ApiHistoryExportButton(
            language: 'en',
            enabled: true,
            load: () => pending.future,
            onBusy: (_) {},
            save: (_, _) async {
              writes++;
              return 'saved';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('api-history-export')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(const ApiHistorySnapshot('id', 0, false, []));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(tester.takeException(), isNull);
  });
}
