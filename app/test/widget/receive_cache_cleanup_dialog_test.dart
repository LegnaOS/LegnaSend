import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:localsend_app/widget/dialogs/receive_cache_cleanup_dialog.dart';
import 'package:localsend_app/widget/dialogs/receive_cache_cleanup_strings.dart';

Widget host({required Future<ReceiveCacheCleanupReport> Function() cleanup, String locale = 'en'}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => ReceiveCacheCleanupDialog(locale: locale, cleanup: cleanup),
        ),
        child: const Text('Open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('confirmation, busy guard, structured results and retry stay inside dialog', (tester) async {
    final pending = Completer<ReceiveCacheCleanupReport>();
    var calls = 0;
    await tester.pumpWidget(
      host(
        cleanup: () {
          calls++;
          return calls == 1 ? pending.future : Future.value(const ReceiveCacheCleanupReport());
        },
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.byKey(const ValueKey('receive-cache-clean')));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('receive-cache-clean'))).onPressed, isNull);
    pending.complete(
      const ReceiveCacheCleanupReport(
        removedFiles: 2,
        removedRecords: 3,
        plannedBytes: 456,
        unlinkedBytes: 123,
        retained: 1,
        failed: 1,
        budgetReached: true,
        reasons: {'parent_unavailable': 1},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Some entries need attention'), findsOneWidget);
    expect(find.text('123'), findsOneWidget);
    expect(find.text('456'), findsOneWidget);
    expect(find.text('Logical bytes planned'), findsOneWidget);
    expect(find.text('Logical bytes removed'), findsOneWidget);
    expect(find.text('Continue cleanup'), findsOneWidget);
    expect(find.textContaining('Destination is offline'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receive-cache-clean')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Scan completed'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('closing pending cleanup does not cancel work or update a disposed dialog', (tester) async {
    final pending = Completer<ReceiveCacheCleanupReport>();
    await tester.pumpWidget(host(cleanup: () => pending.future));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('receive-cache-clean')));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    pending.complete(const ReceiveCacheCleanupReport());
    await tester.pumpAndSettle();
    expect(find.byType(ReceiveCacheCleanupDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese narrow layout, failure and retry remain usable', (tester) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(locale: 'zh-TW', cleanup: () => throw StateError('storage')));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('接收快取管理'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receive-cache-clean')));
    await tester.pumpAndSettle();
    expect(find.text('重新檢查'), findsOneWidget);
    expect(find.textContaining('清理中斷'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared background cleanup disables duplicate action', (tester) async {
    receiveCacheCleanupBusy.value = true;
    addTearDown(() => receiveCacheCleanupBusy.value = false);
    await tester.pumpWidget(host(cleanup: () async => const ReceiveCacheCleanupReport()));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('receive-cache-clean'))).onPressed, isNull);
    receiveCacheCleanupBusy.value = false;
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('receive-cache-clean'))).onPressed, isNotNull);
  });

  test('locale fallback and all native reason codes are mapped', () {
    expect(const ReceiveCacheCleanupStrings('fr').title, 'Receive cache maintenance');
    expect(const ReceiveCacheCleanupStrings('zh-CN').title, '接收缓存管理');
    expect(const ReceiveCacheCleanupStrings('zh-HK').title, '接收快取管理');
    for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      final s = ReceiveCacheCleanupStrings(locale);
      for (final code in [
        'durable_resume',
        'durable_resume_failed',
        'SAF_PUBLICATION_RECONCILED',
        'SAF_PUBLICATION_RECONCILE_RETAINED',
        'ios_scope_busy',
        'ios_scope_list_failed',
        'ios_scoped_maintenance_failed',
        'ios_scope_release_failed',
        'external_scope_required',
        'registry_entry_io',
        'storage_error',
        'unknown_registry_entry',
        'registry_not_regular',
        'target_not_regular',
        'active_registration',
        'active_file',
        'invalid_registry_record',
        'parent_unavailable',
        'parent_identity_unverified',
        'already_absent',
        'file_identity_changed',
        'target_changed_during_cleanup',
        'cache_header_unverified',
        'non_resumable_receive_attempt',
      ]) {
        expect(s.reason(code), isNot(s.reason('unknown')));
      }
    }
  });
  testWidgets('read-only inventory uses lazy detail rows and cleanup reports actual permission failures', (tester) async {
    var cleaned = 0;
    var inspected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ReceiveCacheCleanupDialog(
                  locale: 'en',
                  inspect: () async {
                    inspected++;
                    return ReceiveCacheCleanupReport(
                      inspection: true,
                      examined: 5000,
                      plannedBytes: 5000,
                      entries: List.generate(
                        5000,
                        (i) => ReceiveCacheEntry(
                          id: i.toString().padLeft(64, '0'),
                          fileName: 'file-$i.txt',
                          sourceKind: 'nativeReceive',
                          disposition: 'candidate',
                          reason: 'non_resumable_receive_attempt',
                          plannedBytes: 1,
                        ),
                      ),
                    );
                  },
                  cleanup: () async {
                    cleaned++;
                    return const ReceiveCacheCleanupReport(
                      failed: 1,
                      plannedBytes: 1,
                      entries: [
                        ReceiveCacheEntry(
                          id: 'entry',
                          fileName: 'blocked.txt',
                          sourceKind: 'nativeReceive',
                          disposition: 'failed',
                          reason: 'permission_denied',
                          plannedBytes: 1,
                        ),
                      ],
                    );
                  },
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(inspected, 0);
    expect(cleaned, 0);
    await tester.tap(find.byKey(const ValueKey('receive-cache-inspect')));
    await tester.pumpAndSettle();
    expect(inspected, 1);
    expect(cleaned, 0);
    expect(find.text('Read-only inspection completed'), findsOneWidget);
    expect(find.text('file-4999.txt'), findsNothing);
    expect(find.byKey(const ValueKey('receive-cache-entries')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('receive-cache-clean')));
    await tester.pumpAndSettle();
    expect(cleaned, 1);
    await tester.ensureVisible(find.text('blocked.txt'));
    expect(find.text('Permission denied; entry retained'), findsOneWidget);
    expect(find.text('Planned 1 B · removed 0 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
