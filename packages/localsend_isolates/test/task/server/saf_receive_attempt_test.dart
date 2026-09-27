import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/http_server.dart';
import 'package:localsend_isolates/src/task/server/saf_receive_attempt.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

const channel = MethodChannel('org.localsend.localsend_app/localsend');
const tree = 'content://provider/tree/root%3Aopaque';
const parent = '$tree/document/parent%3Aid';
const tx = 'c5e8e2cf-038c-4cd2-ae10-1c845b607281';
const lease = '8f5f0482-dfed-4f28-a2dc-77c550c2b038';
const coreAttempt = '83864c0d-52b2-4b3a-a2d2-20857577d1a4';
const hash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  late List<MethodCall> calls;
  Object? failOpen;
  Completer<Map<String, Object?>>? publication;
  Completer<Map<String, Object?>>? identity;
  Completer<Map<String, Object?>>? recoveryCompletion;
  const oldTx = 'd5e8e2cf-038c-4cd2-ae10-1c845b607281';
  Map<String, Object?>? recoveryOffer;
  Map<String, Object?>? cleanupOffer;
  Object? cleanupFailure;
  Map<String, Object?> receipt() => {'transactionId': tx, 'uri': '$tree/document/final%3Anumbered', 'size': 4, 'sha256': hash};
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    calls = [];
    api.closed.clear();
    failOpen = null;
    publication = null;
    identity = null;
    recoveryOffer = null;
    cleanupOffer = null;
    cleanupFailure = null;
    recoveryCompletion = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'resolveReceiveDirectory' => parent,
        'beginSafReceiveTransaction' => {
          'transactionId': tx,
          'state': 'ready',
          'cacheUri': '$tree/document/cache',
          'stagingUri': '$tree/document/staging',
          'capabilities': {'readWrite': true, 'seek': true, 'length': true, 'lock': true},
        },
        'openSafReceiveTransaction' => failOpen != null ? throw failOpen! : {'transactionId': tx, 'lease': lease, 'cacheFd': 71, 'stagingFd': 72},
        'bindSafReceiveCacheIdentity' =>
          identity == null ? {'transactionId': tx, 'coreAttemptId': coreAttempt, 'bound': true, 'recovery': ?recoveryOffer} : await identity!.future,
        'completeSafReceiveRecovery' =>
          recoveryCompletion == null
              ? {'transactionId': tx, 'coreAttemptId': coreAttempt, 'sourceTransactionId': oldTx, 'complete': true}
              : await recoveryCompletion!.future,
        'prepareSafRecoveryCleanup' => cleanupOffer,
        'prepareSafPublishedStagingCleanup' => null,
        'deleteSafRecoveryCleanup' => cleanupFailure != null ? throw cleanupFailure! : true,
        'finishSafRecoveryCleanup' => null,
        'publishSafReceiveTransaction' => publication == null ? receipt() : await publication!.future,
        'releaseSafReceiveTransaction' || 'abortSafReceiveTransaction' => {'transactionId': tx, 'complete': true, 'deleted': [], 'retained': []},
        _ => throw StateError('Unexpected ${call.method}; no legacy write fallback'),
      };
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  Future<FileSaveTarget> prepare() => prepareFileSaveTarget(
    destinationDirectory: tree,
    cacheDirectory: '/unused',
    fileName: 'folder/中文 %.txt',
    saveToGallery: false,
    isImage: false,
    createdDirectories: {},
    androidSdkInt: 36,
    receiveSessionId: 'session',
    receiveFileId: 'file',
  );
  Future<void> publish(SafReceiveAttempt attempt, Future<bool> Function(String?) reply, {bool active = true, String transaction = tx}) =>
      answerSafPublication(
        attempt: attempt,
        sessionId: 'session',
        fileId: 'file',
        transactionId: transaction,
        coreAttemptId: coreAttempt,
        size: 4,
        sha256: hash,
        isActive: () => active,
        reply: reply,
      );

  Future<String?> bind(
    SafReceiveAttempt? attempt, {
    bool Function()? isActive,
    String transaction = tx,
    String sessionId = 'session',
    String fileId = 'file',
    String attemptId = coreAttempt,
    String json = '{"version":1}',
  }) async {
    String? error;
    await answerSafCacheIdentity(
      attempt: attempt,
      sessionId: sessionId,
      fileId: fileId,
      transactionId: transaction,
      coreAttemptId: attemptId,
      identityJson: json,
      isActive: isActive ?? () => true,
      reply: (value, recovery) async {
        error = value;
        return true;
      },
    );
    return error;
  }

  test('recovery candidate transfers once and completion drains before release', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{"old":true}', 'sourceFd': 81};
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{"new":true}');
    var transfers = 0;
    Future<bool> reply(SafReceiveRecovery? candidate) async {
      transfers++;
      expect(candidate!.sourceFd, 81);
      expect(candidate.transactionId, oldTx);
      return true;
    }

    await Future.wait([attempt.replyIdentity(reply), attempt.replyIdentity(reply)]);
    expect(transfers, 1);
    recoveryCompletion = Completer();
    final completed = attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash);
    final duplicate = attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash);
    expect(
      () => attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 124, sourceSha256: hash),
      throwsStateError,
    );
    expect(
      () => attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: 'a' * 64),
      throwsStateError,
    );
    final finishing = attempt.finish();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'completeSafReceiveRecovery'), hasLength(1));
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), isEmpty);
    recoveryCompletion!.complete({'transactionId': tx, 'coreAttemptId': coreAttempt, 'sourceTransactionId': oldTx, 'complete': true});
    await Future.wait([completed, duplicate, finishing]);
    expect(api.closed, isEmpty);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
  });

  test('cancelled before candidate handoff closes source once and releases only new transaction', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    identity = Completer();
    var active = true;
    final binding = bind(attempt, isActive: () => active);
    active = false;
    identity!.complete({
      'transactionId': tx,
      'coreAttemptId': coreAttempt,
      'bound': true,
      'recovery': {'transactionId': oldTx, 'identityJson': '{"old":true}', 'sourceFd': 81},
    });
    expect(await binding, isNotNull);
    await attempt.finish();
    expect(api.closed, [81]);
    expect(calls.where((c) => c.method == 'completeSafReceiveRecovery'), isEmpty);
    expect(calls.last.arguments['transactionId'], tx);
  });

  test('mismatched recovery completion does not mutate source and stopped service consumes candidate', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{"old":true}', 'sourceFd': 81};
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{"new":true}');
    expect(
      () => attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash),
      throwsStateError,
    );
    await attempt.replyIdentity(
      (candidate) => HttpServerService().respondReceiveCacheIdentity(
        sessionId: 'session',
        fileId: 'file',
        attemptId: coreAttempt,
        transactionId: tx,
        error: null,
        recovery: candidate,
      ),
    );
    expect(api.closed, [81]);
    expect(
      () => attempt.completeRecovery(coreAttemptId: 'wrong', sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash),
      throwsStateError,
    );
    expect(
      () => attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: tx, sourceLength: 123, sourceSha256: hash),
      throwsStateError,
    );
    await attempt.finish();
    expect(api.closed, [81]);
    expect(calls.where((c) => c.method == 'completeSafReceiveRecovery'), isEmpty);
  });

  test('recovered event rejects wrong identity and late success after cancellation', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{}', 'sourceFd': 81};
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{}');
    await attempt.replyIdentity((_) async => true);
    var active = true;
    Future<String?> answer(String source) async {
      String? error;
      await answerSafCacheRecovered(
        attempt: attempt,
        sessionId: 'session',
        fileId: 'file',
        transactionId: tx,
        coreAttemptId: coreAttempt,
        sourceTransactionId: source,
        sourceLength: 123,
        sourceSha256: hash,
        isActive: () => active,
        reply: (value) async {
          error = value;
          return true;
        },
      );
      return error;
    }

    expect(await answer(tx), isNotNull);
    expect(calls.where((c) => c.method == 'completeSafReceiveRecovery'), isEmpty);
    recoveryCompletion = Completer();
    final answering = answer(oldTx);
    active = false;
    recoveryCompletion!.complete({'transactionId': tx, 'coreAttemptId': coreAttempt, 'sourceTransactionId': oldTx, 'complete': true});
    expect(await answering, isNotNull);
    await attempt.finish();
  });

  test('recovery completion failure prevents provider publication', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{}', 'sourceFd': 81};
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{}');
    await attempt.replyIdentity((_) async => true);
    recoveryCompletion = Completer();
    final completing = attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash);
    final failed = expectLater(completing, throwsA(isA<PlatformException>()));
    final publishing = publish(attempt, (error) async {
      expect(error, isNotNull);
      return true;
    });
    recoveryCompletion!.completeError(PlatformException(code: 'RECOVERY_CHANGED'));
    await failed;
    await publishing;
    await attempt.finish();
    expect(calls.where((c) => c.method == 'publishSafReceiveTransaction'), isEmpty);
    expect(api.closed, isEmpty);
  });

  test('uncertain source handoff retains claim and never closes descriptor twice', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{}', 'sourceFd': 81};
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{}');
    var replies = 0;
    Future<bool> failedReply(SafReceiveRecovery? candidate) {
      replies++;
      throw StateError('bridge unavailable');
    }

    await expectLater(attempt.replyIdentity(failedReply), throwsStateError);
    await expectLater(attempt.replyIdentity(failedReply), throwsStateError);
    expect(replies, 1);
    await expectLater(attempt.finish(), throwsStateError);
    expect(api.closed, isEmpty);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), isEmpty);
  });

  test('published receive survives old-cache cleanup failure and releases its own transaction', () async {
    recoveryOffer = {'transactionId': oldTx, 'identityJson': '{}', 'sourceFd': 81};
    cleanupOffer = {'transactionId': tx, 'sourceTransactionId': oldTx, 'sourceLength': 123, 'sourceSha256': hash, 'descriptor': 91};
    cleanupFailure = PlatformException(code: 'PROVIDER_CHANGED');
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await attempt.bindIdentity(coreAttemptId: coreAttempt, identityJson: '{}');
    await attempt.replyIdentity((_) async => true);
    await attempt.completeRecovery(coreAttemptId: coreAttempt, sourceTransactionId: oldTx, sourceLength: 123, sourceSha256: hash);
    await attempt.publish(attemptId: coreAttempt, size: 4, sha256: hash);
    var released = false;
    await attempt.finish(
      acquireCleanupGuard: ({required descriptor, required expectedLength, required expectedSha256}) async {
        expect(descriptor, 91);
        return () async {
          released = true;
        };
      },
    );
    expect(released, true);
    expect(attempt.publishedUri, isNotNull);
    expect(calls.map((call) => call.method).toList().sublist(calls.length - 2), [
      'releaseSafReceiveTransaction',
      'prepareSafPublishedStagingCleanup',
    ]);
    expect(calls.where((call) => call.method == 'releaseSafReceiveTransaction').single.arguments['published'], true);
    expect(calls.where((c) => c.method == 'finishSafRecoveryCleanup'), hasLength(1));
  });

  test('identity waits for native durable reply and identical duplicates bind once', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    identity = Completer();
    var replied = false;
    final first = bind(attempt).then((value) {
      replied = true;
      return value;
    });
    final duplicate = bind(attempt);
    await Future<void>.delayed(Duration.zero);
    expect(replied, false);
    expect(calls.where((c) => c.method == 'bindSafReceiveCacheIdentity'), hasLength(1));
    identity!.complete({'transactionId': tx, 'coreAttemptId': coreAttempt, 'bound': true});
    expect(await first, isNull);
    expect(await duplicate, isNull);
    await attempt.finish();
  });

  test('identity changed attempt or bytes never overwrites existing binding', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    expect(await bind(attempt), isNull);
    expect(await bind(attempt, json: '{"version":2}'), isNotNull);
    expect(await bind(attempt, attemptId: 'another'), isNotNull);
    expect(calls.where((c) => c.method == 'bindSafReceiveCacheIdentity'), hasLength(1));
    await attempt.finish();
    expect(await bind(attempt), isNotNull);
    expect(calls.where((c) => c.method == 'bindSafReceiveCacheIdentity'), hasLength(1));
  });

  test('unknown cancelled or mismatched identity returns failure without provider mutation', () async {
    final attempt = (await prepare()).saf!;
    expect(await bind(null), isNotNull);
    expect(await bind(attempt, isActive: () => false), isNotNull);
    expect(await bind(attempt, transaction: 'other'), isNotNull);
    expect(await bind(attempt, sessionId: 'other'), isNotNull);
    expect(await bind(attempt, fileId: 'other'), isNotNull);
    expect(calls.where((c) => c.method == 'bindSafReceiveCacheIdentity'), isEmpty);
    await attempt.finish();
  });

  test('cleanup waits for late identity binding then releases even when session was cancelled', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    identity = Completer();
    var active = true;
    final binding = bind(attempt, isActive: () => active);
    final finishing = attempt.finish();
    active = false;
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), isEmpty);
    identity!.complete({'transactionId': tx, 'coreAttemptId': coreAttempt, 'bound': true});
    expect(await binding, isNotNull, reason: 'late native success cannot authorize replaced session');
    await finishing;
    expect(calls.last.method, 'releaseSafReceiveTransaction');
    expect(api.closed, isEmpty, reason: 'Rust already consumed descriptors');
  });

  test('failed identity blocks publication and cleanup still drains binding', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    identity = Completer();
    final binding = bind(attempt);
    String? publicationError;
    final publishing = publish(attempt, (error) async {
      publicationError = error;
      return true;
    });
    final finishing = attempt.finish();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'publishSafReceiveTransaction' || c.method == 'releaseSafReceiveTransaction'), isEmpty);
    identity!.completeError(PlatformException(code: 'IDENTITY_DENIED', details: 'sensitive-source'));
    final error = await binding;
    expect(error, isNotNull);
    expect(error, isNot(contains('sensitive-source')));
    await publishing;
    await finishing;
    expect(publicationError, isNotNull);
    expect(calls.where((c) => c.method == 'publishSafReceiveTransaction'), isEmpty);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
  });

  test('stopped service never acknowledges identity', () async {
    expect(
      await HttpServerService().respondReceiveCacheIdentity(
        sessionId: 'session',
        fileId: 'file',
        attemptId: coreAttempt,
        transactionId: tx,
        error: null,
      ),
      false,
    );
  });

  test('production SAF context selects same-tree cached pair not legacy createFile', () async {
    final target = await prepare();
    expect(calls.map((c) => c.method), ['resolveReceiveDirectory', 'beginSafReceiveTransaction', 'openSafReceiveTransaction']);
    expect(target.path, isNull);
    expect(target.fileDescriptor, isNull);
    expect(target.saf!.opened.cacheFd, 71);
    expect(calls[1].arguments['parentUri'], parent);
    expect(calls[1].arguments['fileName'], '中文 %.txt');
    await target.saf!.finish();
    expect(api.closed, [71, 72]);
  });
  test('retry creates a fresh attempt and never reopens final output', () async {
    final first = await prepare();
    await first.saf!.finish();
    final second = await reopenFileSaveTarget(first);
    expect(second.saf!.attemptId, isNot(first.saf!.attemptId));
    expect(calls.where((c) => c.method == 'openFileForWriting' || c.method == 'createFile'), isEmpty);
    await second.saf!.finish();
  });
  test('provider preparation error fails without direct write and aborts prepared record', () async {
    failOpen = PlatformException(code: 'CAPABILITY_UNSUPPORTED');
    await expectLater(prepare(), throwsA(isA<PlatformException>()));
    expect(calls.last.method, 'abortSafReceiveTransaction');
    expect(api.closed, isEmpty);
  });
  test('late preparation closes both descriptors before provider release', () async {
    var active = true;
    final result = await prepareReceiveTargetIfActive(
      isActive: () => active,
      prepare: () async {
        final target = await prepare();
        active = false;
        return target;
      },
    );
    expect(result, isNull);
    expect(api.closed, [71, 72]);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
  });
  test('stopped service consumes pair once before emitting failure', () async {
    final attempt = (await prepare()).saf!;
    await expectLater(HttpServerService().respondCachedFileUpload(attempt: attempt, fileSize: 4).drain<void>(), throwsStateError);
    await expectLater(HttpServerService().respondCachedFileUpload(attempt: attempt, fileSize: 4).drain<void>(), throwsStateError);
    await attempt.finish();
    expect(api.closed, [71, 72]);
  });
  test('native receipt precedes success reply and supplies actual history URI', () async {
    final target = await prepare();
    final attempt = target.saf!;
    attempt.descriptorsHandedOff = true;
    publication = Completer();
    String? replyError = 'not replied';
    final work = publish(attempt, (error) async {
      replyError = error;
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(replyError, 'not replied');
    expect(attempt.publishedUri, isNull);
    publication!.complete(receipt());
    await work;
    expect(replyError, isNull);
    expect(target.displayPath, '$tree/document/final%3Anumbered');
    await attempt.finish();
    expect(api.closed, isEmpty);
    expect(calls.where((call) => call.method == 'releaseSafReceiveTransaction').single.arguments['published'], true);
    expect(calls.last.method, 'prepareSafPublishedStagingCleanup');
  });
  test('timeout cleanup waits for late successful native publication and preserves it', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    publication = Completer();
    final publishing = publish(attempt, (_) async => false);
    final releasing = attempt.finish();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), isEmpty);
    publication!.complete(receipt());
    await publishing;
    await releasing;
    expect(calls.where((call) => call.method == 'releaseSafReceiveTransaction').single.arguments['published'], true);
    expect(calls.last.method, 'prepareSafPublishedStagingCleanup');
  });
  test('cancelled or mismatched publication does not mutate provider', () async {
    final attempt = (await prepare()).saf!;
    final errors = <String?>[];
    await publish(attempt, (error) async {
      errors.add(error);
      return true;
    }, active: false);
    await publish(attempt, (error) async {
      errors.add(error);
      return true;
    }, transaction: 'other');
    expect(errors, everyElement(isNotNull));
    expect(calls.where((c) => c.method == 'publishSafReceiveTransaction'), isEmpty);
    await attempt.finish();
  });
  test('duplicate publication and release are single native operations', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    await Future.wait([publish(attempt, (_) async => true), publish(attempt, (_) async => false)]);
    await Future.wait([attempt.finish(), attempt.finish()]);
    expect(calls.where((c) => c.method == 'publishSafReceiveTransaction'), hasLength(1));
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), hasLength(1));
    expect(calls.where((c) => c.method == 'prepareSafPublishedStagingCleanup'), hasLength(1));
  });
  test('native failure never yields a successful protocol reply', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    publication = Completer();
    String? failure;
    final work = publish(attempt, (error) async {
      failure = error;
      return true;
    });
    publication!.completeError(PlatformException(code: 'PERMISSION_DENIED'));
    await work;
    expect(failure, contains('PERMISSION_DENIED'));
    expect(attempt.publishedUri, isNull);
    await attempt.finish();
    expect(calls.last.arguments['published'], false);
  });
  test('mismatched receipt stays failure and leaves provider journal authoritative', () async {
    final attempt = (await prepare()).saf!..descriptorsHandedOff = true;
    publication = Completer();
    String? failure;
    final work = publish(attempt, (error) async {
      failure = error;
      return true;
    });
    publication!.complete({...receipt(), 'size': 5});
    await work;
    expect(failure, isNotNull);
    await attempt.finish();
  });
  test('duplicate FD malformed handoff closes integer once', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'openSafReceiveTransaction') return {'transactionId': tx, 'lease': lease, 'cacheFd': 71, 'stagingFd': 71};
      return {'transactionId': tx, 'complete': true};
    });
    await expectLater(
      openSafReceiveTransaction(transactionId: tx, sessionId: 'session', fileId: 'file', attemptId: coreAttempt),
      throwsFormatException,
    );
    expect(api.closed, [71]);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
  });
}

class _Api implements RustLibApi {
  final List<int> closed = [];
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    if (fileDescriptor != null) closed.add(fileDescriptor);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
