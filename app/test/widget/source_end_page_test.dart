import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/source_end_page.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_app/util/source_end_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

class _Notices extends SourceEndNotifier {
  final List<Map<String, Object?>> rows;
  _Notices(this.rows);
  int retries = 0;
  @override
  List<Map<String, Object?>> init() => rows;
  @override
  Future<Map<String, Object?>> retry(String id, String version, String requestId) async {
    retries++;
    return {'accepted': true};
  }
}

void main() {
  const uuid = Uuid();
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('compact source end statuses and real retry ${locale.languageTag}', (tester) async {
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final labels = SourceEndStrings(locale.languageTag);
      final notifier = _Notices([
        {'id': uuid.v4(), 'version': uuid.v4(), 'peerLabel': 'Peer', 'name': 'test.bin', 'state': 'unknown', 'attempts': 1, 'updatedAtUnixMs': 1},
      ]);
      final store = SourceEndStore(read: () async => null, write: (_) async {});
      final container = RefenaContainer(
        overrides: [sourceEndStoreProvider.overrideWithValue(store), sourceEndProvider.overrideWithNotifier((_) => notifier)],
      );
      addTearDown(container.disposeContainer);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          ownsContainer: false,
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              ),
              home: const SourceEndPage(),
            ),
          ),
        ),
      );
      expect(find.text(labels.state('unknown')), findsOneWidget);
      expect(find.text(labels.detail), findsNothing);
      await tester.tap(find.text(labels.retry));
      await tester.pump();
      expect(notifier.retries, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test('public notice snapshot enforces actual UTF8 budget and reports truncation', () {
    final rows = [
      for (var i = 0; i < 512; i++)
        {'id': uuid.v4(), 'version': uuid.v4(), 'peerLabel': '中' * 120, 'name': '文' * 255, 'state': 'pending', 'attempts': 0, 'updatedAtUnixMs': 1},
    ];
    final notifier = _Notices(rows);
    final container = RefenaContainer(overrides: [sourceEndProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(sourceEndProvider);
    final value = notifier.redactedNotices();
    expect(value['truncated'], true);
    expect(utf8.encode(jsonEncode(value)).length, lessThan(256 * 1024));
    expect((value['notices'] as List).length, greaterThan(0));
  });
}
