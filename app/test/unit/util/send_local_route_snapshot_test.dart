import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  const route = LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10');
  final target = Device.empty.copyWith(alias: 'Peer', ip: '192.168.7.11', port: 53317, version: '2.2', fingerprint: 'peer');
  SendJob job({String id = 'route-job', LocalSendRoute? localRoute = route}) => SendJob(
    id: id,
    target: target,
    files: [
      queuedFile('source', 3).copyWith(bytes: [1, 2, 3]),
    ],
    localRoute: localRoute,
  );

  test('every immutable job transition retains its local route snapshot', () {
    final value = job();
    for (final transition in [
      value.withStatus(SendJobStatus.failed),
      value.withRecovery(issue: 'test'),
      value.withCheckpoints({0}, {}),
      value.withAttempt([0]),
      value.withAttemptRevision(2),
    ]) {
      expect(transition.localRoute, same(route));
    }
  });

  test('FIFO and prepared/recovered attempts keep route identity independent of later enqueue', () async {
    final calls = <SendJob>[];
    final gates = <Completer<SessionStatus?>>[];
    final queue = SendQueue(
      execute: (job) {
        calls.add(job);
        final gate = Completer<SessionStatus?>();
        gates.add(gate);
        return gate.future;
      },
      abort: (_) {},
      onChanged: (_) {},
    );
    addTearDown(queue.dispose);
    queue.enqueue(target, job().files, localRoute: route);
    queue.enqueuePrepared(job(id: 'prepared'));
    queue.enqueue(target, job().files);
    expect(calls.single.localRoute, route);
    gates[0].complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    expect(calls[1].localRoute, route);
    gates[1].complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    expect(calls[2].localRoute, isNull);
    gates[2].complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    final restored = SendJob(id: 'restored', target: target, files: job().files, localRoute: route, restored: true, status: SendJobStatus.failed);
    queue.restore([restored]);
    queue.resume(restored);
    expect(calls.last.localRoute, route);
    expect(calls.last.attemptRevision, 1);
    gates.last.complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
  });

  late Directory root;
  late SendRecoveryStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('legna-route-journal-');
    store = SendRecoveryStore(root);
  });
  tearDown(() async {
    await store.releaseSession();
    await root.delete(recursive: true);
  });
  Future<File> manifest() async => File('${(await root.list().where((entry) => entry is Directory).single).path}/manifest.json');

  test('durable capture and fresh restore retain local route, checkpoints and attempt metadata', () async {
    final original = job().withAttempt([0]).withAttemptRevision(3);
    final saved = await store.saveManifest(original);
    expect(saved.localRoute, route);
    expect(saved.attemptIndices, [0]);
    expect(saved.attemptRevision, 3);
    await store.saveProgress(original.id, completed: {0}, skipped: {});
    final fresh = (await SendRecoveryStore(root).load()).single;
    expect(fresh.localRoute, route);
    expect(fresh.completedIndices, {0});
    expect(fresh.status, SendJobStatus.succeeded);
    expect(jsonDecode(await (await manifest()).readAsString())['localRoute'], route.toJson());
  });

  test('legacy missing localRoute loads automatic, but a repeat save cannot change a route', () async {
    await store.saveManifest(job(localRoute: null));
    final file = await manifest();
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    value.remove('localRoute');
    await file.writeAsString(jsonEncode(value));
    expect((await store.load()).single.localRoute, isNull);
    await expectLater(store.saveManifest(job()), throwsA(isA<SendRecoveryException>().having((e) => e.code, 'code', 'invalidRecord')));
    expect((await store.load()).single.localRoute, isNull);
  });

  final invalid = <Object>[
    false,
    [],
    {},
    {'interfaceName': 'en0'},
    {'interfaceName': 'en0', 'localAddress': 4},
    {'interfaceName': '', 'localAddress': '192.168.1.1'},
    {'interfaceName': 'en0\n', 'localAddress': '192.168.1.1'},
    {'interfaceName': 'en0', 'localAddress': 'example.com'},
    {'interfaceName': 'en0', 'localAddress': 'fe80::1%en0'},
    {'interfaceName': 'en0', 'localAddress': '192.168.1.1', 'fallback': true},
  ];
  for (var index = 0; index < invalid.length; index++) {
    test('corrupt persisted local route $index is a reported recovery failure, never automatic fallback', () async {
      await store.saveManifest(job());
      final file = await manifest();
      final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      value['localRoute'] = invalid[index];
      await file.writeAsString(jsonEncode(value));
      expect(await store.load(), isEmpty);
      expect(store.issues.single, endsWith(':invalidRecord'));
    });
  }
}
