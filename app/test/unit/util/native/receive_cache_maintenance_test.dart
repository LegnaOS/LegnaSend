import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:path/path.dart' as p;

void main() {
  test('unsynchronized native policy pauses native deletion but still reconciles provider documents', () async {
    setAutomaticReceiveCacheCleanupAllowed(false);
    var reconciled = false;
    final report = await cleanRegisteredReceiveCaches(
      providerCleanup: () async {
        reconciled = true;
        return {
          'examined': 0,
          'deletedDocuments': 0,
          'removedRecords': 0,
          'retainedTransactions': 0,
          'activeTransactions': 0,
          'publishedReceipts': 0,
          'truncated': false,
          'reasons': <String>[],
        };
      },
    );
    expect(reconciled, true);
    expect(report.reasons['retention_unavailable'], 1);
    expect(report.interrupted, true);
  });
  test('manual cleanup waits for automatic pass then runs its own age override', () async {
    final pending = Completer<String>();
    var manualCalls = 0;
    final automatic = cleanRegisteredReceiveCaches(cleanup: () => pending.future);
    final manual = cleanRegisteredReceiveCaches(
      manual: true,
      cleanup: () async {
        manualCalls++;
        return '{"removedFiles":2,"budgetReached":false}';
      },
    );
    expect(manualCalls, 0);
    pending.complete('{"retained":2,"budgetReached":false}');
    expect((await automatic).retained, 2);
    expect((await manual).removedFiles, 2);
    expect(manualCalls, 1);
  });
  test('manual inspection does not inherit policy-aware in-flight candidates', () async {
    final pending = Completer<String>();
    var manualCalls = 0;
    final automatic = inspectRegisteredReceiveCaches(inspect: () => pending.future);
    final manual = inspectRegisteredReceiveCaches(
      manual: true,
      inspect: () async {
        manualCalls++;
        return '{"inspection":true,"plannedBytes":20,"budgetReached":false}';
      },
    );
    pending.complete('{"inspection":true,"retained":2,"budgetReached":false}');
    expect((await automatic).retained, 2);
    expect((await manual).plannedBytes, 20);
    expect(manualCalls, 1);
  });

  test('provider reconciliation combines counts without double-counting active entries or byte claims', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"examined":1,"removedFiles":1,"unlinkedBytes":20,"budgetReached":false}',
      providerCleanup: () async => {
        'examined': 4,
        'deletedDocuments': 2,
        'removedRecords': 1,
        'retainedTransactions': 2,
        'activeTransactions': 1,
        'publishedReceipts': 1,
        'truncated': true,
        'reasons': ['ACTIVE_RECEIVE', 'PUBLICATION_AMBIGUOUS'],
      },
    );
    expect(result.examined, 5);
    expect(result.removedFiles, 3);
    expect(result.removedRecords, 1);
    expect(result.active, 1);
    expect(result.retained, 1);
    expect(result.unlinkedBytes, 20);
    expect(result.budgetReached, true);
    expect(result.reasons['SAF_PUBLISHED_RECEIPT'], 1);
    expect(result.reasons['SAF_PUBLICATION_AMBIGUOUS'], 1);
  });
  test('acknowledged historical cache removals add once without claiming bytes or records', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
      providerCleanup: () async => {
        'examined': 2,
        'deletedDocuments': 0,
        'recoveryDeletedCaches': 1,
        'removedRecords': 0,
        'retainedTransactions': 1,
        'activeTransactions': 0,
        'publishedReceipts': 1,
        'truncated': false,
        'reasons': ['RECOVERY_STAGING_OWNERSHIP_UNPROVEN'],
      },
    );
    expect(result.removedFiles, 2);
    expect(result.removedRecords, 0);
    expect(result.unlinkedBytes, 0);
    expect(result.retained, 1);
    expect(result.interrupted, false);
  });
  test('invalid recovery deletion count never becomes a successful cleanup report', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
      providerCleanup: () async => {
        'examined': 2,
        'deletedDocuments': 0,
        'recoveryDeletedCaches': -1,
        'removedRecords': 0,
        'retainedTransactions': 1,
        'activeTransactions': 0,
        'publishedReceipts': 1,
        'truncated': false,
        'reasons': <String>[],
      },
    );
    expect(result.removedFiles, 1);
    expect(result.interrupted, true);
    expect(receiveCacheCleanupBusy.value, false);
  });
  test('confirmed publication is counted once without claiming cache deletion', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
      providerCleanup: () async => {
        'examined': 2,
        'deletedDocuments': 0,
        'removedRecords': 0,
        'retainedTransactions': 1,
        'activeTransactions': 0,
        'publishedReceipts': 1,
        'publicationReconciled': 1,
        'truncated': false,
        'reasons': ['PUBLICATION_RECONCILED'],
      },
    );
    expect(result.removedFiles, 1);
    expect(result.removedRecords, 0);
    expect(result.unlinkedBytes, 0);
    expect(result.retained, 1);
    expect(result.reasons['SAF_PUBLICATION_RECONCILED'], 1);
    expect(result.reasons['SAF_PUBLISHED_RECEIPT'], 1);
    expect(result.reasons.containsKey('SAF_PUBLICATION_AMBIGUOUS'), false);
    expect(result.interrupted, false);
  });
  for (final value in [-1, 3, '1']) {
    test('invalid publication reconciliation count $value preserves ordinary results', () async {
      final result = await cleanRegisteredReceiveCaches(
        cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
        providerCleanup: () async => {
          'examined': 2,
          'deletedDocuments': 0,
          'removedRecords': 0,
          'retainedTransactions': 1,
          'activeTransactions': 0,
          'publishedReceipts': 0,
          'publicationReconciled': value,
          'truncated': false,
          'reasons': <String>[],
        },
      );
      expect(result.removedFiles, 1);
      expect(result.reasons.containsKey('SAF_PUBLICATION_RECONCILED'), false);
      expect(result.interrupted, true);
      expect(receiveCacheCleanupBusy.value, false);
    });
  }
  test('acknowledged staging cleanup counts once without inventing bytes or deleting receipts', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
      providerCleanup: () async => {
        'examined': 2,
        'deletedDocuments': 0,
        'recoveryDeletedCaches': 1,
        'publishedStagingDeleted': 1,
        'removedRecords': 0,
        'retainedTransactions': 1,
        'activeTransactions': 0,
        'publishedReceipts': 1,
        'truncated': false,
        'reasons': ['PUBLISHED_STAGING_DELETED', 'PUBLISHED_CACHE_RETAINED'],
      },
    );
    expect(result.removedFiles, 3);
    expect(result.removedRecords, 0);
    expect(result.unlinkedBytes, 0);
    expect(result.retained, 1);
    expect(result.reasons['SAF_PUBLISHED_STAGING_DELETED'], 1);
    expect(result.reasons['SAF_PUBLISHED_RECEIPT'], 1);
    expect(result.interrupted, false);
  });
  for (final value in [-1, 3, '1']) {
    test('invalid published staging count $value preserves completed ordinary cleanup', () async {
      final result = await cleanRegisteredReceiveCaches(
        cleanup: () async => '{"removedFiles":1,"budgetReached":false}',
        providerCleanup: () async => {
          'examined': 2,
          'deletedDocuments': 0,
          'publishedStagingDeleted': value,
          'removedRecords': 0,
          'retainedTransactions': 1,
          'activeTransactions': 0,
          'publishedReceipts': 1,
          'truncated': false,
          'reasons': <String>[],
        },
      );
      expect(result.removedFiles, 1);
      expect(result.interrupted, true);
      expect(receiveCacheCleanupBusy.value, false);
    });
  }
  test('provider failure preserves completed ordinary-path cleanup results', () async {
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"removedFiles":2,"budgetReached":false}',
      providerCleanup: () async => throw StateError('provider offline'),
    );
    expect(result.removedFiles, 2);
    expect(result.interrupted, true);
    expect(receiveCacheCleanupBusy.value, false);
  });
  test('provider records are checked even if ordinary registry scan fails', () async {
    var called = false;
    final result = await cleanRegisteredReceiveCaches(
      cleanup: () async => throw StateError('registry offline'),
      providerCleanup: () async {
        called = true;
        return {
          'examined': 1,
          'deletedDocuments': 0,
          'removedRecords': 0,
          'retainedTransactions': 1,
          'activeTransactions': 0,
          'publishedReceipts': 0,
          'truncated': false,
          'reasons': ['INTERRUPTED_RECEIVE'],
        };
      },
    );
    expect(called, true);
    expect(result.interrupted, true);
    expect(result.retained, 1);
  });

  test('registry is under application support, not Downloads or temp', () async {
    String? configured;
    final support = p.absolute('support', '中文 % app');
    await initializeReceiveCacheMaintenance(
      portable: false,
      supportDirectory: () async => support,
      configure: (value) async => configured = value,
    );
    expect(configured, p.join(support, '.legnasend-receive-registry'));
  });
  test('portable registry stays beside the actual portable settings', () async {
    String? configured;
    final portable = p.absolute('portable', 'app');
    await initializeReceiveCacheMaintenance(
      portable: true,
      portableSettingsPath: () => p.join(portable, 'settings.json'),
      supportDirectory: () => throw StateError('must not use another identity'),
      configure: (value) async => configured = value,
    );
    expect(configured, p.join(portable, '.legnasend-receive-registry'));
  });
  test('support or permission errors do not invent a cleanup destination', () async {
    var calls = 0;
    await initializeReceiveCacheMaintenance(
      portable: false,
      supportDirectory: () => throw StateError('permission'),
      configure: (_) async => calls++,
    );
    expect(calls, 0);
    await initializeReceiveCacheMaintenance(
      portable: false,
      supportDirectory: () async => p.absolute('support'),
      configure: (_) async => throw StateError('disk full'),
    );
  });
  test('background cleanup handles report and errors without stopping receiving', () async {
    var calls = 0;
    await cleanRegisteredReceiveCaches(
      cleanup: () async {
        calls++;
        return '{"removedFiles":2,"unlinkedBytes":10}';
      },
    );
    await cleanRegisteredReceiveCaches(cleanup: () => throw StateError('disk offline'));
    await cleanRegisteredReceiveCaches(cleanup: () async => 'invalid json');
    expect(calls, 1);
  });
  test('startup advances bounded batches and caps automatic cleanup work', () async {
    var calls = 0;
    await cleanRegisteredReceiveCaches(
      cleanup: () async {
        calls++;
        return '{"budgetReached":true}';
      },
    );
    expect(calls, 16);
  });
  test('cleanup aggregates bounded passes and retains completed counts on failure', () async {
    var calls = 0;
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async {
        calls++;
        if (calls == 3) throw StateError('disconnected');
        return '{"examined":4,"removedFiles":2,"removedRecords":3,"plannedBytes":16,"unlinkedBytes":10,"active":1,"retained":1,"failed":1,"budgetReached":true,"reasons":{"active_file":1}}';
      },
    );
    expect(report.examined, 8);
    expect(report.removedFiles, 4);
    expect(report.removedRecords, 6);
    expect(report.plannedBytes, 32);
    expect(report.unlinkedBytes, 20);
    expect(report.budgetReached, true);
    expect(report.active, 2);
    expect(report.retained, 2);
    expect(report.failed, 2);
    expect(report.batches, 2);
    expect(report.reasons, {'active_file': 2});
    expect(report.interrupted, true);
    expect(report.needsAttention, true);
    expect(receiveCacheCleanupBusy.value, false);
  });
  test('concurrent callers share one operation and busy state resets on error', () async {
    final pending = Completer<String>();
    var calls = 0;
    final first = cleanRegisteredReceiveCaches(
      cleanup: () {
        calls++;
        return pending.future;
      },
    );
    final second = cleanRegisteredReceiveCaches(cleanup: () => throw StateError('duplicate must not run'));
    expect(identical(first, second), true);
    expect(receiveCacheCleanupBusy.value, true);
    pending.completeError(StateError('storage'));
    expect((await first).interrupted, true);
    expect(calls, 1);
    expect(receiveCacheCleanupBusy.value, false);
    expect((await cleanRegisteredReceiveCaches(cleanup: () async => '{}')).interrupted, false);
  });
  test('manual scan reports continuation and parser rejects malformed counts', () async {
    final report = await cleanRegisteredReceiveCaches(cleanup: () async => '{"budgetReached":true}', maxBatches: 1);
    expect(report.budgetReached, true);
    expect(report.batches, 1);
    for (final json in ['[]', '{"failed":-1}', '{"plannedBytes":-1}', '{"active":"1"}', '{"budgetReached":1}', '{"reasons":{"bad":false}}']) {
      expect(() => ReceiveCacheCleanupReport.parse(json), throwsFormatException);
    }
    expect(() => cleanRegisteredReceiveCaches(maxBatches: 0), throwsArgumentError);
  });
  test('generic mobile cache cleanup leaves all managed receive names alone', () {
    for (final name in ['.legnasend-receive-a.ls', '.legnasend-receive-a.part', '.legnasend-receive-future', 'user.ls', 'user.LS']) {
      expect(shouldPreserveReceiveTemporaryName(name), true);
    }
    for (final name in ['unrelated.tmp', 'other.part']) {
      expect(shouldPreserveReceiveTemporaryName(name), false);
    }
  });
  test('inspection is read-only and reports bounded per-entry results without starting cleanup', () async {
    var calls = 0;
    final report = await inspectRegisteredReceiveCaches(
      inspect: () async {
        calls++;
        return jsonEncode({
          'inspection': true,
          'examined': 1,
          'plannedBytes': 42,
          'entries': [
            {
              'id': 'a' * 64,
              'fileName': '秘密.txt',
              'sourceKind': 'nativeReceive',
              'disposition': 'candidate',
              'reason': 'non_resumable_receive_attempt',
              'plannedBytes': 42,
              'unlinkedBytes': 0,
            },
          ],
        });
      },
    );
    expect(calls, 1);
    expect(report.inspection, isTrue);
    expect(report.entries.single.disposition, 'candidate');
    expect(report.entries.single.plannedBytes, 42);
    expect(report.entries.single.toJson(includeDisplayName: false).containsKey('fileName'), isFalse);
    expect(report.removedFiles, 0);
    expect(receiveCacheInspectionBusy.value, isFalse);
  });

  test('inspection refuses any purported removal and clears its busy guard', () async {
    final report = await inspectRegisteredReceiveCaches(inspect: () async => '{"inspection":true,"removedFiles":1}');
    expect(report.interrupted, isTrue);
    expect(report.removedFiles, 0);
    expect(receiveCacheInspectionBusy.value, isFalse);
  });

  test('inspection bounds passes, keeps completed detail on failure, and shares concurrent work', () async {
    final pending = Completer<String>();
    final first = inspectRegisteredReceiveCaches(inspect: () => pending.future);
    final second = inspectRegisteredReceiveCaches(inspect: () => throw StateError('must share'));
    expect(identical(first, second), isTrue);
    pending.complete('{"inspection":true,"examined":1,"budgetReached":true}');
    expect((await first).budgetReached, isTrue);
    var calls = 0;
    final report = await inspectRegisteredReceiveCaches(
      maxBatches: 3,
      inspect: () async {
        if (++calls == 2) throw StateError('disk offline');
        return '{"inspection":true,"examined":3,"budgetReached":true}';
      },
    );
    expect(report.examined, 3);
    expect(report.interrupted, isTrue);
    expect(report.inspection, isTrue);
    expect(report.budgetReached, isTrue);
  });

  test('per-entry failures preserve logical planned and successful unlink counts separately', () {
    final report = ReceiveCacheCleanupReport.parse(
      jsonEncode({
        'entries': [
          {
            'id': 'b' * 64,
            'fileName': '缓存.bin',
            'sourceKind': 'directoryUpload',
            'disposition': 'failed',
            'reason': 'permission_denied',
            'plannedBytes': 1024,
            'unlinkedBytes': 0,
          },
        ],
        'failed': 1,
        'plannedBytes': 1024,
        'entriesTruncated': true,
      }),
    );
    expect(report.entries.single.reason, 'permission_denied');
    expect(report.entries.single.unlinkedBytes, 0);
    expect(report.entriesTruncated, isTrue);
    expect(report.needsAttention, isTrue);
    expect(() => ReceiveCacheEntry.parse({'disposition': 'fabricated'}), throwsFormatException);
  });
}
