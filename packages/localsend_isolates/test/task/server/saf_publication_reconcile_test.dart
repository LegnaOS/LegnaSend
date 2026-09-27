import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

class _Guard extends Fake implements RsReceivePublicationGuard {
  final Future<void> Function() finish;
  _Guard(this.finish);
  @override
  Future<void> release() => finish();
}

class _Api implements RustLibApi {
  Future<RsReceivePublicationGuard> Function(int, BigInt, String)? acquire;
  @override
  Future<RsReceivePublicationGuard> crateApiServerAcquireReceivePublicationGuard({
    required int fileDescriptor,
    required BigInt length,
    required String sha256,
  }) => acquire!(fileDescriptor, length, sha256);
  final closed = <int>[];
  bool failClose = false;
  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    if (fileDescriptor != null) closed.add(fileDescriptor);
    if (failClose) throw StateError('close failed');
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
  const next = 'd5e8e2cf-038c-4cd2-ae10-1c845b607281';
  const reconciliation = '8f5f0482-dfed-4f28-a2dc-77c550c2b038';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> order;
  Map<String, Object>? preparation;
  Object? confirmation;
  Completer<Object?>? confirming;
  Completer<void>? guardRelease, witnessFinish;
  bool locked = false, guardFails = false, releaseFails = false, finishFails = false;
  setUp(() {
    api.closed.clear();
    api.failClose = false;
    api.acquire = null;
    order = [];
    locked = guardFails = releaseFails = finishFails = false;
    confirming = null;
    guardRelease = witnessFinish = null;
    preparation = {'transactionId': tx, 'reconciliationId': reconciliation, 'fileDescriptor': 91, 'size': 123, 'sha256': 'A' * 64};
    confirmation = {'transactionId': tx, 'reconciled': true};
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'prepareSafReceivePublicationReconcile':
          expect(call.arguments, {'transactionId': tx});
          return preparation;
        case 'confirmSafReceivePublicationReconcile':
          expect(call.arguments, {'transactionId': tx, 'reconciliationId': reconciliation});
          expect(locked, true, reason: 'strict shared guard covers native persistent confirmation');
          return confirming == null ? confirmation : await confirming!.future;
        case 'finishSafReceivePublicationReconcile':
          expect(call.arguments, {'transactionId': tx, 'reconciliationId': reconciliation});
          expect(locked, false);
          if (finishFails) throw PlatformException(code: 'FINISH_FAILED', details: reconciliation);
          await witnessFinish?.future;
          return null;
        default:
          throw StateError('Unexpected ${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<SafCleanupRelease> acquire({required int fileDescriptor, required BigInt length, required String sha256}) async {
    order.add('guard');
    expect(fileDescriptor, 91);
    expect(length, BigInt.from(preparation!['size'] as int));
    expect(sha256, 'a' * 64);
    // This injected boundary, like Rust, consumes the FD even on rejection.
    if (guardFails) throw StateError('hash or strict lock rejected');
    locked = true;
    return () async {
      order.add('release');
      await guardRelease?.future;
      locked = false;
      if (releaseFails) throw StateError('release failed');
    };
  }

  Future<bool> run() => reconcileSafReceivePublication(transactionId: tx, acquireGuard: acquire);
  Future<void> waitFor(String operation) async {
    while (!order.contains(operation)) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Map<String, Object> snapshot(List<Object> candidates, {List<Object> cleanup = const []}) => {
    'examined': 2,
    'removedRecords': 0,
    'deletedDocuments': 0,
    'retainedTransactions': 2,
    'activeTransactions': 0,
    'publishedReceipts': 0,
    'truncated': false,
    'reasons': ['PUBLICATION_AMBIGUOUS', 'PUBLICATION_AMBIGUOUS'],
    'publicationReconcileCandidates': candidates,
    'recoveryCleanupCandidates': cleanup,
  };

  test('strict shared guard spans actual confirm and both finalizers drain in order', () async {
    confirming = Completer();
    guardRelease = Completer();
    witnessFinish = Completer();
    var completed = false;
    final pending = run().then((value) {
      completed = true;
      return value;
    });
    await waitFor('confirmSafReceivePublicationReconcile');
    expect(order, ['prepareSafReceivePublicationReconcile', 'guard', 'confirmSafReceivePublicationReconcile']);
    expect(locked, true);
    confirming!.complete(confirmation);
    await waitFor('release');
    expect(completed, false);
    expect(order.contains('finishSafReceivePublicationReconcile'), false);
    guardRelease!.complete();
    await waitFor('finishSafReceivePublicationReconcile');
    expect(completed, false);
    witnessFinish!.complete();
    expect(await pending, true);
    expect(order, [
      'prepareSafReceivePublicationReconcile',
      'guard',
      'confirmSafReceivePublicationReconcile',
      'release',
      'finishSafReceivePublicationReconcile',
    ]);
    expect(api.closed, isEmpty);
  });

  test('default production path forwards complete proof to bridge and releases its opaque guard', () async {
    api.acquire = (fd, length, hash) async {
      final release = await acquire(fileDescriptor: fd, length: length, sha256: hash);
      return _Guard(release);
    };
    expect(await reconcileSafReceivePublication(transactionId: tx), true);
    expect(order, [
      'prepareSafReceivePublicationReconcile',
      'guard',
      'confirmSafReceivePublicationReconcile',
      'release',
      'finishSafReceivePublicationReconcile',
    ]);
    expect(api.closed, isEmpty);
  });

  test('rejected hash or unsupported lock never confirms and finishes witness without double close', () async {
    guardFails = true;
    await expectLater(run(), throwsStateError);
    expect(order, ['prepareSafReceivePublicationReconcile', 'guard', 'finishSafReceivePublicationReconcile']);
    expect(api.closed, isEmpty);
  });

  test('native confirmation failure still releases guard and finishes witness', () async {
    confirming = Completer();
    final pending = run();
    final expected = expectLater(pending, throwsA(isA<PlatformException>()));
    await waitFor('confirmSafReceivePublicationReconcile');
    confirming!.completeError(PlatformException(code: 'DOCUMENT_CHANGED'));
    await expected;
    expect(order.sublist(order.length - 2), ['release', 'finishSafReceivePublicationReconcile']);
    expect(locked, false);
  });

  test('only matching durable true acknowledgement counts; malformed confirmation is not success', () async {
    for (final invalid in [
      null,
      {'transactionId': tx, 'reconciled': false},
      {'transactionId': next, 'reconciled': true},
      {'transactionId': tx},
    ]) {
      order.clear();
      confirmation = invalid;
      await expectLater(run(), throwsFormatException);
      expect(order.sublist(order.length - 2), ['release', 'finishSafReceivePublicationReconcile']);
    }
  });

  test('no candidate acquires no descriptor or guard; zero-size exact file is accepted', () async {
    final original = preparation!;
    preparation = null;
    expect(await run(), false);
    expect(order, ['prepareSafReceivePublicationReconcile']);
    preparation = {...original, 'size': 0};
    expect(await run(), true);
  });

  test('malformed handoff closes FD and finishes recognizable witness independently', () async {
    final original = preparation!;
    for (final invalid in [
      {...original, 'sha256': 'bad'},
      {...original, 'size': -1},
      {...original, 'transactionId': next},
      {...original, 'fileDescriptor': -1},
      {...original, 'fileDescriptor': 0x80000000},
    ]) {
      api.closed.clear();
      order.clear();
      preparation = invalid;
      await expectLater(run(), throwsFormatException);
      expect(api.closed, invalid['fileDescriptor'] == 91 ? [91] : isEmpty);
      expect(order, ['prepareSafReceivePublicationReconcile', 'finishSafReceivePublicationReconcile']);
    }
    preparation = {...original, 'reconciliationId': 'bad'};
    api.closed.clear();
    order.clear();
    await expectLater(run(), throwsFormatException);
    expect(api.closed, [91]);
    expect(order, ['prepareSafReceivePublicationReconcile']);
    preparation = {...original, 'sha256': 'bad'};
    api.failClose = true;
    finishFails = true;
    order.clear();
    await expectLater(run(), throwsFormatException);
    expect(order.last, 'finishSafReceivePublicationReconcile');
  });

  test('invalid caller identities never reach platform', () async {
    await expectLater(prepareSafReceivePublicationReconcile(transactionId: '../bad'), throwsArgumentError);
    await expectLater(confirmSafReceivePublicationReconcile(transactionId: tx, reconciliationId: 'bad'), throwsArgumentError);
    await expectLater(finishSafReceivePublicationReconcile(transactionId: 'bad', reconciliationId: reconciliation), throwsArgumentError);
    expect(order, isEmpty);
  });

  test('bounded private candidates are stripped, deduplicated and independently retried', () async {
    final extra = 'e5e8e2cf-038c-4cd2-ae10-1c845b607281';
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => snapshot([
        {'transactionId': tx, 'reconciliationId': reconciliation},
        {'transactionId': tx.toUpperCase()},
        {'transactionId': '../bad'},
        {'transactionId': next},
        {'transactionId': extra},
      ]),
    );
    final visited = <String>[];
    final report = await reconcileSafReceiveTransactions(
      limit: 4,
      publicationReconcile: ({required transactionId}) async {
        visited.add(transactionId);
        if (transactionId == tx) throw StateError('provider offline');
        return true;
      },
    );
    expect(visited, [tx, next]);
    expect(report['publicationReconciled'], 1);
    expect(report['publishedReceipts'], 0, reason: 'retain original snapshot rather than count confirmation twice');
    expect(report['retainedTransactions'], 2, reason: 'unknown staging and cache remain registered');
    expect(report['reasons'], ['PUBLICATION_AMBIGUOUS', 'PUBLICATION_RECONCILED']);
    expect(report.containsKey('publicationReconcileCandidates'), false);
    expect(report.containsKey('recoveryCleanupCandidates'), false);
    expect(report.toString(), isNot(contains(reconciliation)));
    expect(report.toString(), isNot(contains(tx)));
    expect(report['deletedDocuments'], 0);
  });

  test('failed or false confirmations leave ambiguity; cleanup still runs', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => snapshot(
        [
          {'transactionId': tx},
          {'transactionId': next},
        ],
        cleanup: [
          {'transactionId': tx, 'lease': reconciliation},
        ],
      ),
    );
    var cleaned = false;
    final report = await reconcileSafReceiveTransactions(
      publicationReconcile: ({required transactionId}) async {
        if (transactionId == tx) throw StateError('not proven');
        return false;
      },
      cleanup: ({required transactionId, required lease}) async {
        cleaned = true;
        return true;
      },
    );
    expect(cleaned, true);
    expect(report['publicationReconciled'], 0);
    expect(report['reasons'], ['PUBLICATION_AMBIGUOUS', 'PUBLICATION_AMBIGUOUS']);
    expect(report['recoveryDeletedCaches'], 1);
  });

  test('confirmed receipt survives both finalizer failures and subsequent cleanup failure', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'reconcileSafReceiveTransactions':
          return snapshot(
            [
              {'transactionId': tx},
            ],
            cleanup: [
              {'transactionId': next, 'lease': reconciliation},
            ],
          );
        case 'prepareSafReceivePublicationReconcile':
          return preparation;
        case 'confirmSafReceivePublicationReconcile':
          expect(locked, true);
          return confirmation;
        case 'finishSafReceivePublicationReconcile':
          throw PlatformException(code: 'FINISH_FAILED', details: reconciliation);
        default:
          throw StateError('Unexpected method');
      }
    });
    releaseFails = true;
    var cleaned = false;
    final report = await reconcileSafReceiveTransactions(
      publicationReconcile: ({required transactionId}) => reconcileSafReceivePublication(transactionId: transactionId, acquireGuard: acquire),
      cleanup: ({required transactionId, required lease}) async {
        cleaned = true;
        throw StateError('cleanup failed');
      },
    );
    expect(cleaned, true);
    expect(report['publicationReconciled'], 1);
    expect(report['recoveryDeletedCaches'], 0);
    expect(report['reasons'], ['PUBLICATION_AMBIGUOUS', 'PUBLICATION_RECONCILED']);
    expect(order.sublist(order.length - 2), ['release', 'finishSafReceivePublicationReconcile']);
    expect(report.toString(), isNot(contains(reconciliation)));
  });
}
