import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

class _Guard extends Fake implements RsReceiveCleanupGuard {
  final Future<void> Function() finish;
  _Guard(this.finish);
  @override
  Future<void> release() => finish();
}

class _Api implements RustLibApi {
  final closed = <int>[];
  bool failClose = false;
  Future<RsReceiveCleanupGuard> Function(int, BigInt, String)? acquire;
  @override
  Future<RsReceiveCleanupGuard> crateApiServerAcquireReceiveCleanupGuard({
    required int descriptor,
    required BigInt expectedLength,
    required String expectedSha256,
  }) => acquire!(descriptor, expectedLength, expectedSha256);
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
  const tx = 'c5e8e2cf-038c-4cd2-ae10-1c845b607281', next = 'd5e8e2cf-038c-4cd2-ae10-1c845b607281';
  const cleanupId = '8f5f0482-dfed-4f28-a2dc-77c550c2b038';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> order;
  Map<String, Object>? preparation;
  Completer<bool?>? deletion;
  Completer<void>? releaseWait, finishWait;
  bool? deleted;
  bool locked = false, guardFails = false, releaseFails = false, finishFails = false;
  setUp(() {
    api.closed.clear();
    api.failClose = false;
    api.acquire = null;
    order = [];
    locked = guardFails = releaseFails = finishFails = false;
    deletion = null;
    releaseWait = finishWait = null;
    deleted = true;
    preparation = {'transactionId': tx, 'cleanupId': cleanupId, 'descriptor': 91, 'length': 123, 'sha256': 'A' * 64};
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'prepareSafPublishedStagingCleanup':
          expect(call.arguments, {'transactionId': tx});
          return preparation;
        case 'deleteSafPublishedStagingCleanup':
          expect(call.arguments, {'transactionId': tx, 'cleanupId': cleanupId});
          expect(locked, true);
          return deletion == null ? deleted : await deletion!.future;
        case 'finishSafPublishedStagingCleanup':
          expect(call.arguments, {'transactionId': tx, 'cleanupId': cleanupId});
          expect(locked, false);
          if (finishFails) throw PlatformException(code: 'FINISH_FAILED', details: cleanupId);
          await finishWait?.future;
          return null;
        default:
          throw StateError('Unexpected ${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<SafCleanupRelease> acquire({required int descriptor, required BigInt expectedLength, required String expectedSha256}) async {
    order.add('guard');
    expect(descriptor, 91);
    expect(expectedLength, BigInt.from(preparation!['length'] as int));
    expect(expectedSha256, 'a' * 64);
    if (guardFails) throw StateError('strict EX or digest failed');
    locked = true;
    return () async {
      order.add('release');
      await releaseWait?.future;
      locked = false;
      if (releaseFails) throw StateError('release failed');
    };
  }

  Future<bool> run() => cleanupSafPublishedStaging(transactionId: tx, acquireGuard: acquire);
  Future<void> waitFor(String method) async {
    while (!order.contains(method)) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Map<String, Object> snapshot(List<Object> candidates) => {
    'examined': 2,
    'removedRecords': 0,
    'deletedDocuments': 0,
    'retainedTransactions': 2,
    'activeTransactions': 0,
    'publishedReceipts': 2,
    'truncated': true,
    'reasons': <String>[],
    'publishedStagingCleanupCandidates': candidates,
  };

  test('EX guard covers true delete drain, then independent guard and witness finalizers complete', () async {
    deletion = Completer();
    releaseWait = Completer();
    finishWait = Completer();
    var done = false;
    final operation = run().then((result) {
      done = true;
      return result;
    });
    await waitFor('deleteSafPublishedStagingCleanup');
    expect(locked, true);
    expect(order, ['prepareSafPublishedStagingCleanup', 'guard', 'deleteSafPublishedStagingCleanup']);
    deletion!.complete(true);
    await waitFor('release');
    expect(done, false);
    expect(order.contains('finishSafPublishedStagingCleanup'), false);
    releaseWait!.complete();
    await waitFor('finishSafPublishedStagingCleanup');
    expect(done, false);
    finishWait!.complete();
    expect(await operation, true);
    expect(order.sublist(order.length - 2), ['release', 'finishSafPublishedStagingCleanup']);
    expect(api.closed, isEmpty);
  });

  test('default production path passes complete proof to existing EX guard', () async {
    api.acquire = (descriptor, length, hash) async => _Guard(await acquire(descriptor: descriptor, expectedLength: length, expectedSha256: hash));
    expect(await cleanupSafPublishedStaging(transactionId: tx), true);
    expect(order, ['prepareSafPublishedStagingCleanup', 'guard', 'deleteSafPublishedStagingCleanup', 'release', 'finishSafPublishedStagingCleanup']);
  });

  test('guard rejection consumes FD once, skips deletion and still finishes native witness', () async {
    guardFails = true;
    await expectLater(run(), throwsStateError);
    expect(order, ['prepareSafPublishedStagingCleanup', 'guard', 'finishSafPublishedStagingCleanup']);
    expect(api.closed, isEmpty);
  });

  test('false replay, missing result and native error do not claim a deletion', () async {
    deleted = false;
    expect(await run(), false);
    deleted = null;
    await expectLater(run(), throwsFormatException);
    deletion = Completer();
    order.clear();
    final pending = run();
    final expected = expectLater(pending, throwsA(isA<PlatformException>()));
    await waitFor('deleteSafPublishedStagingCleanup');
    deletion!.completeError(PlatformException(code: 'REPLACED'));
    await expected;
    expect(order.sublist(order.length - 2), ['release', 'finishSafPublishedStagingCleanup']);
  });

  test('null candidate does no extra work; zero-length proof still reaches the guard', () async {
    final original = preparation!;
    preparation = null;
    expect(await run(), false);
    expect(order, ['prepareSafPublishedStagingCleanup']);
    preparation = {...original, 'length': 0};
    expect(await run(), true);
  });

  test('malformed handoffs close only untransferred valid FD and independently finish known witness', () async {
    final original = preparation!;
    for (final invalid in [
      {...original, 'sha256': 'bad'},
      {...original, 'length': -1},
      {...original, 'transactionId': next},
      {...original, 'descriptor': -1},
      {...original, 'descriptor': 0x80000000},
    ]) {
      preparation = invalid;
      order.clear();
      api.closed.clear();
      await expectLater(run(), throwsFormatException);
      expect(api.closed, invalid['descriptor'] == 91 ? [91] : isEmpty);
      expect(order, ['prepareSafPublishedStagingCleanup', 'finishSafPublishedStagingCleanup']);
    }
    preparation = {...original, 'cleanupId': 'bad'};
    order.clear();
    api.closed.clear();
    await expectLater(run(), throwsFormatException);
    expect(api.closed, [91]);
    expect(order, ['prepareSafPublishedStagingCleanup']);
    preparation = {...original, 'sha256': 'bad'};
    order.clear();
    api.failClose = finishFails = true;
    await expectLater(run(), throwsFormatException);
    expect(order.last, 'finishSafPublishedStagingCleanup');
  });

  test('malformed caller IDs never invoke native cleanup', () async {
    await expectLater(prepareSafPublishedStagingCleanup(transactionId: '../bad'), throwsArgumentError);
    await expectLater(deleteSafPublishedStagingCleanup(transactionId: tx, cleanupId: 'bad'), throwsArgumentError);
    await expectLater(finishSafPublishedStagingCleanup(transactionId: 'bad', cleanupId: cleanupId), throwsArgumentError);
    expect(order, isEmpty);
  });

  test('scan candidates are bounded, case-insensitively deduplicated and private tokens stripped', () async {
    final extra = 'e5e8e2cf-038c-4cd2-ae10-1c845b607281';
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => snapshot([
        {'transactionId': tx, 'cleanupId': cleanupId},
        {'transactionId': tx.toUpperCase()},
        {'transactionId': '../bad'},
        {'transactionId': next},
        {'transactionId': extra},
      ]),
    );
    final visited = <String>[];
    final report = await reconcileSafReceiveTransactions(
      limit: 4,
      publishedStagingCleanup: ({required transactionId}) async {
        visited.add(transactionId);
        if (transactionId == tx) throw StateError('offline');
        return true;
      },
    );
    expect(visited, [tx, next]);
    expect(report['publishedStagingDeleted'], 1);
    expect(report['retainedTransactions'], 2);
    expect(report['deletedDocuments'], 0);
    expect(report['publishedReceipts'], 2);
    expect(report.containsKey('publishedStagingCleanupCandidates'), false);
    expect(report.toString(), isNot(contains(cleanupId)));
    expect(report.toString(), isNot(contains(tx)));
  });

  test('actual deletion remains counted if both finalizers fail; scan snapshots stay unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'reconcileSafReceiveTransactions':
          return snapshot([
            {'transactionId': tx},
          ]);
        case 'prepareSafPublishedStagingCleanup':
          return preparation;
        case 'deleteSafPublishedStagingCleanup':
          expect(locked, true);
          return true;
        case 'finishSafPublishedStagingCleanup':
          throw PlatformException(code: 'CLOSE_FAILED', details: cleanupId);
        default:
          throw StateError('Unexpected method');
      }
    });
    releaseFails = true;
    final report = await reconcileSafReceiveTransactions(publishedStagingCleanup: ({required transactionId}) => run());
    expect(report['publishedStagingDeleted'], 1);
    expect(report['deletedDocuments'], 0);
    expect(order.sublist(order.length - 2), ['release', 'finishSafPublishedStagingCleanup']);
  });

  test('staging failure never erases confirmed publication or acknowledged old-cache cleanup', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        ...snapshot([
          {'transactionId': tx},
        ]),
        'publicationReconcileCandidates': [
          {'transactionId': tx},
        ],
        'recoveryCleanupCandidates': [
          {'transactionId': tx, 'lease': cleanupId},
        ],
      },
    );
    final report = await reconcileSafReceiveTransactions(
      publicationReconcile: ({required transactionId}) async => true,
      cleanup: ({required transactionId, required lease}) async => true,
      publishedStagingCleanup: ({required transactionId}) async => throw StateError('provider offline'),
    );
    expect(report['publicationReconciled'], 1);
    expect(report['recoveryDeletedCaches'], 1);
    expect(report['publishedStagingDeleted'], 0);
    expect(report.keys.any((key) => key.endsWith('Candidates')), false);
    expect(report.toString(), isNot(contains(cleanupId)));
  });

  test('normal published release waits for native receive drain before best-effort cleanup', () async {
    final nativeRelease = Completer<Object?>(), cleanup = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      return nativeRelease.future;
    });
    var finished = false;
    final pending = releaseSafReceiveTransaction(
      transactionId: tx,
      lease: cleanupId,
      published: true,
      publishedStagingCleanup: ({required transactionId}) {
        expect(transactionId, tx);
        order.add('cleanup');
        return cleanup.future;
      },
    ).then((_) => finished = true);
    await waitFor('releaseSafReceiveTransaction');
    expect(order, ['releaseSafReceiveTransaction']);
    nativeRelease.complete({'transactionId': tx, 'complete': false});
    await waitFor('cleanup');
    expect(finished, false);
    cleanup.completeError(StateError('optional cleanup failed'));
    await pending;
    expect(finished, true);
  });

  test('unpublished release and malformed release acknowledgement never begin staging cleanup', () async {
    var cleaned = 0;
    messenger.setMockMethodCallHandler(channel, (_) async => {'transactionId': tx, 'complete': true});
    await releaseSafReceiveTransaction(
      transactionId: tx,
      lease: cleanupId,
      published: false,
      publishedStagingCleanup: ({required transactionId}) async {
        cleaned++;
        return true;
      },
    );
    messenger.setMockMethodCallHandler(channel, (_) async => {'transactionId': next, 'complete': true});
    await expectLater(
      releaseSafReceiveTransaction(
        transactionId: tx,
        lease: cleanupId,
        published: true,
        publishedStagingCleanup: ({required transactionId}) async {
          cleaned++;
          return true;
        },
      ),
      throwsFormatException,
    );
    expect(cleaned, 0);
  });

  test('published release defaults to real staging pipeline without changing successful receive result', () async {
    api.acquire = (descriptor, length, hash) async => _Guard(await acquire(descriptor: descriptor, expectedLength: length, expectedSha256: hash));
    messenger.setMockMethodCallHandler(channel, (call) async {
      order.add(call.method);
      switch (call.method) {
        case 'releaseSafReceiveTransaction':
          return {'transactionId': tx, 'complete': true};
        case 'prepareSafPublishedStagingCleanup':
          return preparation;
        case 'deleteSafPublishedStagingCleanup':
          expect(locked, true);
          return true;
        case 'finishSafPublishedStagingCleanup':
          return null;
        default:
          throw StateError('Unexpected method');
      }
    });
    await releaseSafReceiveTransaction(transactionId: tx, lease: cleanupId, published: true);
    expect(order, [
      'releaseSafReceiveTransaction',
      'prepareSafPublishedStagingCleanup',
      'guard',
      'deleteSafPublishedStagingCleanup',
      'release',
      'finishSafPublishedStagingCleanup',
    ]);
  });
}
