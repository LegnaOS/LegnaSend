import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

class _Api implements RustLibApi {
  final closed = <int>[];
  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    if (fileDescriptor != null) closed.add(fileDescriptor);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  const tx = 'c5e8e2cf-038c-4cd2-ae10-1c845b607281';
  const source = 'd5e8e2cf-038c-4cd2-ae10-1c845b607281';
  const lease = '8f5f0482-dfed-4f28-a2dc-77c550c2b038';
  late List<String> order;
  Map<String, Object>? preparation;
  Completer<bool>? deletion;
  bool locked = false;
  Object? guardFailure;
  setUp(() {
    api.closed.clear();
    order = [];
    locked = false;
    guardFailure = null;
    deletion = null;
    preparation = {'transactionId': tx, 'sourceTransactionId': source, 'sourceLength': 123, 'sourceSha256': 'a' * 64, 'descriptor': 91};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'prepareSafRecoveryCleanup':
          expect(call.arguments, {'transactionId': tx, 'lease': lease});
          return preparation;
        case 'deleteSafRecoveryCleanup':
          expect(locked, true, reason: 'strict Rust lock must cover the entire native delete');
          expect(call.arguments, {'transactionId': tx, 'lease': lease, 'sourceTransactionId': source});
          return deletion == null ? true : await deletion!.future;
        case 'finishSafRecoveryCleanup':
          expect(locked, false);
          expect(call.arguments, {'transactionId': tx, 'sourceTransactionId': source});
          return null;
        default:
          throw StateError('Unexpected ${call.method}');
      }
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  Future<SafCleanupRelease> acquire({required int descriptor, required BigInt expectedLength, required String expectedSha256}) async {
    order.add('acquire');
    expect(descriptor, 91);
    expect(expectedLength, BigInt.from(123));
    expect(expectedSha256, 'a' * 64);
    if (guardFailure != null) throw guardFailure!;
    locked = true;
    return () async {
      order.add('release');
      locked = false;
    };
  }

  Future<bool> run() => cleanupSafReceiveRecovery(transactionId: tx, lease: lease, acquireGuard: acquire);

  test('reconcile strips private leases, bounds work and continues after one failure', () async {
    final next = 'e5e8e2cf-038c-4cd2-ae10-1c845b607281';
    final extra = 'f5e8e2cf-038c-4cd2-ae10-1c845b607281';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'reconcileSafReceiveTransactions');
      expect(call.arguments, {'limit': 2});
      return {
        'examined': 2,
        'removedRecords': 0,
        'deletedDocuments': 0,
        'retainedTransactions': 2,
        'activeTransactions': 0,
        'publishedReceipts': 2,
        'truncated': true,
        'reasons': <String>[],
        'recoveryCleanupCandidates': [
          {'transactionId': tx, 'lease': lease},
          {'transactionId': next, 'lease': lease},
          {'transactionId': extra, 'lease': lease},
        ],
      };
    });
    final visited = <String>[];
    final report = await reconcileSafReceiveTransactions(
      limit: 2,
      cleanup: ({required transactionId, required lease}) async {
        visited.add(transactionId);
        if (transactionId == tx) throw StateError('temporarily locked');
        return true;
      },
    );
    expect(visited, [tx, next]);
    expect(report['recoveryDeletedCaches'], 1);
    expect(report['retainedTransactions'], 2, reason: 'scan snapshot is not rewritten');
    expect(report['deletedDocuments'], 0);
    expect(report.containsKey('recoveryCleanupCandidates'), false);
    expect(report.toString(), isNot(contains(lease)));
  });

  test('reconcile malformed, duplicate and unsuccessful candidates do not inflate deletion count', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'examined': 1,
        'removedRecords': 0,
        'deletedDocuments': 0,
        'retainedTransactions': 1,
        'activeTransactions': 0,
        'publishedReceipts': 1,
        'truncated': false,
        'reasons': <String>[],
        'recoveryCleanupCandidates': [
          {'transactionId': '../bad', 'lease': lease},
          {'transactionId': tx, 'lease': lease},
          {'transactionId': tx, 'lease': lease},
        ],
      },
    );
    var attempts = 0;
    final report = await reconcileSafReceiveTransactions(
      cleanup: ({required transactionId, required lease}) async {
        attempts++;
        return false;
      },
    );
    expect(attempts, 1);
    expect(report['recoveryDeletedCaches'], 0);
    expect(report.containsKey('recoveryCleanupCandidates'), false);
  });

  test('confirmed deletion is counted even if both finalizers fail and both are attempted', () async {
    final original = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    original.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      if (call.method == 'reconcileSafReceiveTransactions') {
        return {
          'examined': 1,
          'removedRecords': 0,
          'deletedDocuments': 0,
          'retainedTransactions': 1,
          'activeTransactions': 0,
          'publishedReceipts': 1,
          'truncated': false,
          'reasons': <String>[],
          'recoveryCleanupCandidates': [
            {'transactionId': tx, 'lease': lease},
          ],
        };
      }
      if (call.method == 'prepareSafRecoveryCleanup') return preparation;
      if (call.method == 'deleteSafRecoveryCleanup') return true;
      if (call.method == 'finishSafRecoveryCleanup') throw PlatformException(code: 'CLOSE_FAILED', details: lease);
      throw StateError('Unexpected method');
    });
    final report = await reconcileSafReceiveTransactions(
      cleanup: ({required transactionId, required lease}) => cleanupSafReceiveRecovery(
        transactionId: transactionId,
        lease: lease,
        acquireGuard: ({required descriptor, required expectedLength, required expectedSha256}) async => () async {
          order.add('guard-release');
          throw StateError('release failed');
        },
      ),
    );
    expect(report['recoveryDeletedCaches'], 1);
    expect(report['deletedDocuments'], 0);
    expect(order.sublist(order.length - 2), ['guard-release', 'finishSafRecoveryCleanup']);
    expect(report.toString(), isNot(contains(lease)));
  });

  test('guard stays held until native deletion really drains, then both witnesses release', () async {
    deletion = Completer();
    final pending = run();
    while (!order.contains('deleteSafRecoveryCleanup')) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(locked, true);
    expect(order, ['prepareSafRecoveryCleanup', 'acquire', 'deleteSafRecoveryCleanup']);
    deletion!.complete(true);
    await pending;
    expect(order, ['prepareSafRecoveryCleanup', 'acquire', 'deleteSafRecoveryCleanup', 'release', 'finishSafRecoveryCleanup']);
    expect(api.closed, isEmpty, reason: 'Rust consumes descriptor even when it rejects');
  });

  test('unsupported guard skips deletion but closes native witness', () async {
    guardFailure = StateError('lock unsupported');
    await expectLater(run(), throwsStateError);
    expect(order, ['prepareSafRecoveryCleanup', 'acquire', 'finishSafRecoveryCleanup']);
    expect(api.closed, isEmpty);
  });

  test('deletion false or error keeps cleanup ordered and releases guard', () async {
    deletion = Completer()..complete(false);
    await run();
    expect(order.sublist(order.length - 2), ['release', 'finishSafRecoveryCleanup']);
    order.clear();
    deletion = Completer();
    final pending = run();
    final expected = expectLater(pending, throwsA(isA<PlatformException>()));
    while (!order.contains('deleteSafRecoveryCleanup')) {
      await Future<void>.delayed(Duration.zero);
    }
    deletion!.completeError(PlatformException(code: 'PROVIDER_CHANGED'));
    await expected;
    expect(order.sublist(order.length - 2), ['release', 'finishSafRecoveryCleanup']);
    expect(locked, false);
  });

  test('no candidate needs no guard; malformed handoff closes untransferred descriptor', () async {
    final valid = preparation!;
    preparation = null;
    await run();
    expect(order, ['prepareSafRecoveryCleanup']);
    order.clear();
    preparation = {...valid, 'sourceSha256': 'bad'};
    await expectLater(run(), throwsFormatException);
    expect(api.closed, [91]);
    expect(order, ['prepareSafRecoveryCleanup', 'finishSafRecoveryCleanup']);
  });
}
