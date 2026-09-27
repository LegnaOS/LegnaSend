import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  const id = '19a3b3f0-141b-4c41-b421-2f68a0e929d3';
  const lease = '29a3b3f0-141b-4c41-b421-2f68a0e929d3';
  const identity = '{"taskId":"$id"}';
  late List<MethodCall> calls;
  Object? response;
  Future<SafReceiveRecovery?> bind({String transaction = id, String leaseId = lease, String attempt = 'core-attempt', String json = identity}) =>
      bindSafReceiveCacheIdentity(transactionId: transaction, lease: leaseId, coreAttemptId: attempt, identityJson: json);
  setUp(() {
    calls = [];
    api.closed.clear();
    response = {'transactionId': id, 'coreAttemptId': 'core-attempt', 'bound': true};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  test('bind awaits explicit matching durable acknowledgement and forwards full identity', () async {
    await bind();
    expect(calls.single.method, 'bindSafReceiveCacheIdentity');
    expect(calls.single.arguments, {'transactionId': id, 'lease': lease, 'coreAttemptId': 'core-attempt', 'identityJson': identity});
  });
  test('optional source descriptor requires exact identity and malformed handoff closes once', () async {
    const old = '39a3b3f0-141b-4c41-b421-2f68a0e929d3';
    response = {
      'transactionId': id,
      'coreAttemptId': 'core-attempt',
      'bound': true,
      'recovery': {'transactionId': old, 'identityJson': '{"old":true}', 'sourceFd': 81},
    };
    final candidate = await bind();
    expect(candidate!.transactionId, old);
    expect(candidate.sourceFd, 81);
    expect(api.closed, isEmpty);
    for (final oldId in [id, 'malformed']) {
      response = {
        'transactionId': id,
        'coreAttemptId': 'core-attempt',
        'bound': true,
        'recovery': {'transactionId': oldId, 'identityJson': '{}', 'sourceFd': 82},
      };
      await expectLater(bind(), throwsFormatException);
    }
    expect(api.closed, [82, 82]);
  });

  test('recovery completion requires exact explicit acknowledgement', () async {
    const old = '39a3b3f0-141b-4c41-b421-2f68a0e929d3';
    response = {'transactionId': id, 'coreAttemptId': 'core-attempt', 'sourceTransactionId': old, 'complete': true};
    await completeSafReceiveRecovery(
      transactionId: id,
      lease: lease,
      coreAttemptId: 'core-attempt',
      sourceTransactionId: old,
      sourceLength: 123,
      sourceSha256: 'a' * 64,
    );
    expect(calls.single.method, 'completeSafReceiveRecovery');
    response = {'transactionId': id, 'sourceTransactionId': old, 'complete': true};
    await expectLater(
      completeSafReceiveRecovery(
        transactionId: id,
        lease: lease,
        coreAttemptId: 'core-attempt',
        sourceTransactionId: old,
        sourceLength: 123,
        sourceSha256: 'a' * 64,
      ),
      throwsFormatException,
    );
  });

  test('invalid envelope never invokes native mutation', () async {
    await expectLater(bind(transaction: 'bad'), throwsArgumentError);
    await expectLater(bind(leaseId: 'bad'), throwsArgumentError);
    await expectLater(bind(attempt: ''), throwsArgumentError);
    await expectLater(bind(json: ''), throwsArgumentError);
    await expectLater(bind(json: 'x' * 16385), throwsArgumentError);
    expect(calls, isEmpty);
  });
  test('missing mismatched or false acknowledgement never succeeds', () async {
    for (final invalid in [
      null,
      {},
      {'transactionId': id, 'coreAttemptId': 'other', 'bound': true},
      {'transactionId': 'wrong', 'coreAttemptId': 'core-attempt', 'bound': true},
      {'transactionId': id, 'coreAttemptId': 'core-attempt', 'bound': false},
    ]) {
      response = invalid;
      await expectLater(bind(), throwsFormatException);
    }
  });
  test('native authorization or persistence failure propagates without fallback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'PERMISSION_DENIED');
    });
    await expectLater(bind(), throwsA(isA<PlatformException>()));
    expect(calls.length, 1);
  });
}

class _Api implements RustLibApi {
  final closed = <int>[];
  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    if (fileDescriptor != null) closed.add(fileDescriptor);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
