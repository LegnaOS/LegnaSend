import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

const channel = MethodChannel('org.localsend.localsend_app/localsend');
const id = '19a3b3f0-141b-4c41-b421-2f68a0e929d3';
const tree = 'content://provider/tree/root%3Aopaque';
const parent = '$tree/document/db%3Aparent';
const cache = '$tree/document/opaque%3Als';
const staging = '$tree/document/opaque%3Apart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late Map<String, Object?> response;
  Future<SafReceivePreparation> begin({String name = '中文 %.txt', String session = 'session'}) => beginSafReceiveTransaction(
    treeUri: tree,
    parentUri: parent,
    fileName: name,
    sessionId: session,
    fileId: 'file',
    attemptId: 'attempt',
  );
  setUp(() {
    calls = [];
    response = {
      'transactionId': id,
      'state': 'ready',
      'cacheUri': cache,
      'stagingUri': staging,
      'capabilities': {'readWrite': true, 'seek': true, 'length': true, 'lock': true},
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('preparation retains opaque IDs and transmits identity without token or FD', () async {
    final prepared = await begin();
    expect(prepared.transactionId, id);
    expect(prepared.cacheUri, cache);
    expect(prepared.stagingUri, staging);
    expect(calls.single.method, 'beginSafReceiveTransaction');
    expect(calls.single.arguments, {
      'treeUri': tree,
      'parentUri': parent,
      'fileName': '中文 %.txt',
      'sessionId': 'session',
      'fileId': 'file',
      'attemptId': 'attempt',
    });
  });
  test('invalid names and missing identities do not mutate provider', () async {
    for (final name in ['', '..', '../file', r'folder\file', 'file\u0000']) {
      await expectLater(begin(name: name), throwsArgumentError);
    }
    await expectLater(begin(session: ''), throwsArgumentError);
    expect(calls, isEmpty);
  });
  test('native capability failure propagates without direct-write fallback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'CAPABILITY_UNSUPPORTED');
    });
    await expectLater(begin(), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'CAPABILITY_UNSUPPORTED')));
    expect(calls.map((c) => c.method), ['beginSafReceiveTransaction']);
  });
  for (final key in ['readWrite', 'seek', 'length', 'lock']) {
    test('missing $key proof rejects successful-looking native result', () async {
      (response['capabilities'] as Map).remove(key);
      await expectLater(begin(), throwsFormatException);
      expect(calls.length, 1);
    });
  }
  test('malformed or aliased document results never trigger guessed deletion', () async {
    for (final value in ['/path', 'content://elsewhere/document/x', 'content://provider/tree/other/document/id', cache, '$staging?query=x']) {
      response['stagingUri'] = value;
      await expectLater(begin(), throwsFormatException);
    }
    expect(calls.every((c) => c.method == 'beginSafReceiveTransaction'), true);
  });
  test('foundation rejects accidental detached descriptor handoff', () async {
    response['fd'] = 10;
    await expectLater(begin(), throwsFormatException);
  });
  test('abort keeps partial result and exact provider URIs', () async {
    response = {
      'transactionId': id,
      'deleted': [cache],
      'retained': [staging],
      'complete': false,
      'reasons': ['PERMISSION_DENIED'],
    };
    final result = await abortSafReceiveTransaction(id);
    expect(result.deleted, [cache]);
    expect(result.retained, [staging]);
    expect(result.complete, false);
    expect(result.reasons, ['PERMISSION_DENIED']);
    expect(() => result.deleted.add(staging), throwsUnsupportedError);
    expect(calls.single.arguments, {'transactionId': id});
  });
  test('already absent cleanup is idempotent and does not require guessed URIs', () async {
    response = {'transactionId': id, 'deleted': [], 'retained': [], 'complete': true};
    for (var i = 0; i < 2; i++) {
      expect((await abortSafReceiveTransaction(id)).complete, true);
    }
  });
  test('invalid and mismatched abort identities rejected', () async {
    await expectLater(abortSafReceiveTransaction('../bad'), throwsArgumentError);
    expect(calls, isEmpty);
    response = {'transactionId': 'another', 'deleted': [], 'retained': [], 'complete': true};
    await expectLater(abortSafReceiveTransaction(id), throwsFormatException);
  });
  test('contradictory complete or deleted outcomes rejected', () async {
    for (final report in [
      {
        'transactionId': id,
        'deleted': [],
        'retained': [staging],
        'complete': true,
      },
      {
        'transactionId': id,
        'deleted': [cache],
        'retained': [cache],
        'complete': false,
      },
      {
        'transactionId': id,
        'deleted': [cache, cache],
        'retained': [],
        'complete': true,
      },
    ]) {
      response = report;
      await expectLater(abortSafReceiveTransaction(id), throwsFormatException);
    }
  });
}
