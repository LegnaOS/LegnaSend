import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legnasend/ios_receive');
  const id = '19a3b3f0-141b-4c41-b421-2f68a0e929d3';
  const path = '/private/provider/中文 % folder ';
  final calls = <MethodCall>[];
  Object? reply;
  setUp(() {
    calls.clear();
    reply = {'leaseId': id, 'path': path};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'release' ? null : reply;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  test('exact authorized path is preserved and lease releases once', () async {
    final lease = await acquireIosReceiveScope(path);
    expect(lease!.path, path);
    expect(calls.single.arguments, {'path': path});
    await lease.release();
    await lease.release();
    expect(calls.map((call) => call.method), ['acquire', 'release']);
    expect(calls.last.arguments, {'leaseId': id});
  });
  test('only native null classifies the sandbox', () async {
    reply = null;
    expect(await acquireIosReceiveScope(path), isNull);
    expect(calls.length, 1);
  });
  test('mismatched path closes valid returned lease but never rewrites destination', () async {
    reply = {'leaseId': id, 'path': '/different'};
    await expectLater(acquireIosReceiveScope(path), throwsFormatException);
    expect(calls.map((call) => call.method), ['acquire', 'release']);
  });
  test('invalid lease and input never become a scope', () async {
    reply = {'leaseId': 'bad', 'path': path};
    await expectLater(acquireIosReceiveScope(path), throwsFormatException);
    expect(calls.length, 1);
    calls.clear();
    await expectLater(acquireIosReceiveScope('relative'), throwsArgumentError);
    await expectLater(acquireIosReceiveScope('/bad\u0000'), throwsArgumentError);
    expect(calls, isEmpty);
  });
  test('native denial propagates without a bare path fallback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'receiveGrantUnavailable');
    });
    await expectLater(acquireIosReceiveScope(path), throwsA(isA<PlatformException>()));
    expect(calls.length, 1);
  });
  test('grant marker is queried separately and does not acquire a scope', () async {
    reply = true;
    expect(await isGrantedIosReceivePath(path), true);
    expect(calls.single.method, 'isGrantedPath');
    expect(calls.single.arguments, {'path': path});
  });
  test('maintenance uses its own non-overlapping acquire and ordinary release', () async {
    final lease = await acquireIosReceiveMaintenanceScope(path);
    expect(calls.single.method, 'acquireMaintenance');
    expect(calls.single.arguments, {'path': path});
    await lease!.release();
    expect(calls.last.method, 'release');
  });
  test('listed roots preserve exact paths and never acquire or probe authority', () async {
    reply = [path, '/provider/other'];
    expect(await listIosGrantedReceivePaths(), [path, '/provider/other']);
    expect(calls.single.method, 'listGrantedPaths');
    expect(calls.single.arguments, null);
  });
  test('listed root response rejects malformed, excessive, duplicate and relative values', () async {
    for (final invalid in [
      null,
      {},
      [1],
      [path, path],
      List.generate(129, (i) => '/$i'),
    ]) {
      reply = invalid;
      await expectLater(listIosGrantedReceivePaths(), throwsFormatException);
    }
    for (final invalid in [
      ['relative'],
      ['/bad\u0000'],
    ]) {
      reply = invalid;
      await expectLater(listIosGrantedReceivePaths(), throwsArgumentError);
    }
  });
  test('busy maintenance propagates without falling back to receiving acquire', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'receiveGrantBusy');
    });
    await expectLater(acquireIosReceiveMaintenanceScope(path), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'receiveGrantBusy')));
    expect(calls.map((c) => c.method), ['acquireMaintenance']);
  });
}
