import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/api/transfer_management.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:uuid/uuid.dart';

const uuid = Uuid();
final owner = uuid.v4();
final foreign = uuid.v4();
const channel = HttpChannel(host: '127.0.0.1', port: 53317, https: false);
const peer = Device(
  signalingId: null,
  ip: '127.0.0.1',
  version: '2.2',
  port: 53317,
  https: false,
  fingerprint: 'peer',
  alias: 'Peer',
  deviceModel: null,
  deviceType: DeviceType.desktop,
  download: true,
  channels: [channel],
);
CrossFile file([String name = 'example.txt']) => CrossFile(
  name: name,
  fileType: FileType.text,
  size: 6,
  thumbnail: null,
  asset: null,
  path: '/private/secret/example.txt',
  bytes: [115, 101, 99, 114, 101, 116],
  lastModified: null,
  lastAccessed: null,
);

class Fixture {
  List<Device> devices = [peer];
  List<LocalNetworkAddress> addresses = [];
  List<CrossFile> selection = [file()];
  List<SendJob> jobs = [];
  final executions = <String, Completer<SessionStatus?>>{};
  final aborted = <String>[];
  var scanGate = Completer<void>();
  DateTime now = DateTime.utc(2026);
  int scans = 0;
  int enqueues = 0;
  late final SendQueue queue;
  late final TransferManagement manager;
  Fixture({int receiptLimit = 512, Future<void> Function()? beforeRemove}) {
    queue = SendQueue(
      execute: (job) => (executions[job.id] = Completer<SessionStatus?>()).future,
      abort: (job) {
        aborted.add(job.id);
      },
      onChanged: (value) => jobs = value,
    );
    manager = TransferManagement(
      readDevices: () => devices,
      readLocalAddresses: () => addresses,
      interfaceBinding: true,
      enqueueRouted: (device, files, selected, route) {
        enqueues++;
        return queue.enqueue(device, files, selectedChannel: selected, localRoute: route);
      },
      readSelection: () => selection,
      readJobs: () => jobs,
      enqueue: (device, files, selected) {
        enqueues++;
        return queue.enqueue(device, files, selectedChannel: selected);
      },
      cancel: queue.cancel,
      remove: (id) async {
        await beforeRemove?.call();
        queue.remove(id);
      },
      scan: () {
        scans++;
        return scanGate.future;
      },
      receiptLimit: receiptLimit,
      clock: () => now,
      readProgress: (_) => (transferredBytes: 3, bytesPerSecond: 12),
    );
  }
  Future<Map<String, dynamic>> call(
    String operation, {
    Map<String, Object?> fields = const {},
    String? principal,
    Future<bool> Function()? claim,
  }) async =>
      jsonDecode(
            await manager.execute(
              request: jsonEncode({
                'operation': 'transfer.$operation',
                'principal': principal ?? owner,
                'workspaces': ['*'],
                ...fields,
              }),
              claim: claim ?? () async => true,
            ),
          )
          as Map<String, dynamic>;
  Future<Map<String, Object?>> sendFields() async {
    final listed = await call('devices');
    final selected = await call('selection');
    return {'deviceId': listed['body']['devices'][0]['id'], 'selectionVersion': selected['body']['selectionVersion'], 'requestId': uuid.v4()};
  }

  Future<String> send() async => (await call('send', fields: await sendFields()))['body']['task']['id'] as String;
  void dispose() {
    queue.dispose();
    for (final future in executions.values) {
      if (!future.isCompleted) future.complete(SessionStatus.canceledBySender);
    }
    if (!scanGate.isCompleted) scanGate.complete();
  }
}

void main() {
  test('explicit route IDs retire, creation is idempotent and retry preserves the route', () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    fixture.addresses = [const LocalNetworkAddress(interfaceName: 'en-fixture', interfaceIndex: 7, address: '192.0.2.7')];
    final list = (await fixture.call('devices'))['body'];
    final routeId = list['localRoutes'][0]['id'] as String;
    expect(list['localRoutes'][0]['binding'], 'interfaceAndSource');
    final fields = {...await fixture.sendFields(), 'localRouteId': routeId};
    final created = await fixture.call('send', fields: fields);
    expect(created['status'], 202);
    final task = created['body']['task'];
    expect(task['localRouteId'], routeId);
    final job = fixture.jobs.single;
    expect(job.localRoute!.interfaceName, 'en-fixture');
    expect((await fixture.call('send', fields: fields))['body']['replayed'], true);
    expect(fixture.enqueues, 1);
    expect((await fixture.call('send', fields: {...fields, 'localRouteId': uuid.v4()}))['status'], 409);
    fixture.queue.cancel(job.id);
    final retried = await fixture.call('retry', fields: {'transferId': job.id, 'requestId': uuid.v4()});
    expect(retried['status'], 202);
    expect(fixture.jobs.last.localRoute, job.localRoute);
    fixture.addresses = [];
    fixture.manager.refreshLocalRoutes();
    expect((await fixture.call('send', fields: {...fields, 'requestId': uuid.v4()}))['body']['error']['code'], 'local_route_unavailable');
    fixture.addresses = [const LocalNetworkAddress(interfaceName: 'en-fixture', interfaceIndex: 7, address: '192.0.2.7')];
    final newRoute = ((await fixture.call('devices'))['body']['localRoutes'] as List).single['id'];
    expect(newRoute, isNot(routeId));
    expect((await fixture.call('send', fields: {...fields, 'requestId': uuid.v4()}))['status'], 409);
  });

  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  test('history removal waits for durable deletion before acknowledging success', () async {
    f.dispose();
    final deletion = Completer<void>();
    f = Fixture(beforeRemove: () => deletion.future);
    final id = await f.send();
    f.executions[id]!.complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    var responded = false;
    final result = f.call('remove', fields: {'transferId': id}).then((value) {
      responded = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(responded, false);
    expect(f.jobs, hasLength(1));
    deletion.complete();
    expect((await result)['status'], 200);
    expect(f.jobs, isEmpty);
  });

  test('device IDs and confirmed channel IDs are stable, unknown and signaling-only devices stay absent', () async {
    f.devices = [
      peer,
      peer.copyWith(
        fingerprint: 'signal',
        channels: [const SignalingChannel(signalingServer: 'https://private')],
      ),
    ];
    final first = (await f.call('devices'))['body'];
    expect(first['devices'], hasLength(1));
    expect((await f.call('devices'))['body'], first);
    final id = first['devices'][0]['id'];
    expect((await f.call('device', fields: {'deviceId': id}))['body']['device'], first['devices'][0]);
    f.devices = [];
    expect((await f.call('device', fields: {'deviceId': id}))['status'], 404);
  });

  test('selection manifest is bounded, names only, and never includes source paths or text contents', () async {
    f.selection = List.generate(101, (_) => file('folder/example.txt'));
    final response = await f.call('selection');
    expect(response['body']['files'], hasLength(100));
    expect(response['body']['totalCount'], 101);
    expect(response['body']['totalBytes'], 606);
    expect(response['body']['truncated'], true);
    final encoded = jsonEncode(response);
    expect(encoded, isNot(contains('/private')));
    expect(encoded, isNot(contains('secret')));
    expect(encoded, isNot(contains('folder/')));
    final version = response['body']['selectionVersion'];
    expect((await f.call('selection'))['body']['selectionVersion'], version);
    f.selection = [...f.selection];
    expect((await f.call('selection'))['body']['selectionVersion'], isNot(version));
  });

  test('claim boundary rechecks selection and prevents stale send after permission delay', () async {
    final fields = await f.sendFields();
    final claim = Completer<bool>();
    final pending = f.call('send', fields: fields, claim: () => claim.future);
    await Future<void>.delayed(Duration.zero);
    f.selection = [file('replacement.txt')];
    claim.complete(true);
    final response = await pending;
    expect(response['status'], 409);
    expect(response['body']['error']['code'], 'selection_changed');
    expect(f.enqueues, 0);
  });

  test('accepted request receipt is replayed before selection checks and conflicting payload never resends', () async {
    final fields = await f.sendFields();
    final original = await f.call('send', fields: fields);
    expect(original['status'], 202);
    expect(original['body']['replayed'], false);
    expect(original['body']['task']['status'], 'running');
    f.selection = [];
    final replay = await f.call('send', fields: fields);
    expect(replay['body']['task']['id'], original['body']['task']['id']);
    expect(replay['body']['replayed'], true);
    expect(f.enqueues, 1);
    expect((await f.call('send', fields: {...fields, 'deviceId': uuid.v4()}))['status'], 409);
    expect(f.jobs.single.selectedChannel, channel);
    expect(original['body']['task']['transferredBytes'], 3);
    expect(original['body']['task']['bytesPerSecond'], 12);
  });

  test('parallel duplicate requests create exactly one real queue job', () async {
    final fields = await f.sendFields();
    final responses = await Future.wait(List.generate(8, (_) => f.call('send', fields: fields)));
    expect(f.enqueues, 1);
    expect(responses.map((r) => r['body']['task']['id']).toSet(), hasLength(1));
    expect(responses.where((r) => r['body']['replayed'] == false), hasLength(1));
  });

  test('ownership hides foreign and native UI jobs from reads and every control', () async {
    final id = await f.send();
    final native = f.queue.enqueue(peer, [file()]);
    expect((await f.call('list', principal: foreign))['body']['tasks'], isEmpty);
    expect((await f.call('list'))['body']['tasks'], hasLength(1));
    for (final operation in ['get', 'cancel', 'remove', 'retry']) {
      expect(
        (await f.call(operation, fields: {'transferId': id, if (operation == 'retry') 'requestId': uuid.v4()}, principal: foreign))['status'],
        404,
      );
      expect((await f.call(operation, fields: {'transferId': native, if (operation == 'retry') 'requestId': uuid.v4()}))['status'], 404);
    }
    expect(f.aborted, isEmpty);
  });

  test('cancel keeps real queue drain guard; removal cannot falsely report released active task', () async {
    final id = await f.send();
    final response = await f.call('cancel', fields: {'transferId': id});
    expect(response['body']['task']['status'], 'canceled');
    expect(f.aborted, [id]);
    expect((await f.call('remove', fields: {'transferId': id}))['status'], 409);
    f.executions[id]!.complete(SessionStatus.canceledBySender);
    await Future<void>.delayed(Duration.zero);
    expect((await f.call('remove', fields: {'transferId': id}))['body']['removed'], true);
    expect((await f.call('get', fields: {'transferId': id}))['status'], 404);
  });

  test('retry sends original complete selection on pinned channel using a fresh task and receipt', () async {
    final id = await f.send();
    final retryFields = {'transferId': id, 'requestId': uuid.v4()};
    expect((await f.call('retry', fields: retryFields))['status'], 409);
    f.executions[id]!.complete(SessionStatus.declined);
    await Future<void>.delayed(Duration.zero);
    f.selection = [file('other.txt')];
    final retry = await f.call('retry', fields: retryFields);
    final next = retry['body']['task']['id'];
    expect(retry['status'], 202);
    expect(next, isNot(id));
    expect(retry['body']['task']['retryOf'], id);
    expect(f.jobs.last.files.single.name, 'example.txt');
    expect(f.jobs.last.selectedChannel, channel);
    expect((await f.call('retry', fields: retryFields))['body']['replayed'], true);
    expect(f.enqueues, 2);
  });

  test('receipt survives explicit removal and never silently evicts at capacity', () async {
    f.dispose();
    f = Fixture(receiptLimit: 1);
    final fields = await f.sendFields();
    final id = (await f.call('send', fields: fields))['body']['task']['id'];
    f.executions[id]!.complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    await f.call('remove', fields: {'transferId': id});
    expect((await f.call('send', fields: fields))['body']['task']['removed'], true);
    expect((await f.call('send', fields: {...fields, 'requestId': uuid.v4()}))['status'], 429);
    expect(f.enqueues, 1);
  });

  test('locally removed history retains redacted idempotent receipt but releases API control', () async {
    final fields = await f.sendFields();
    final id = (await f.call('send', fields: fields))['body']['task']['id'];
    f.executions[id]!.complete(SessionStatus.finished);
    await Future<void>.delayed(Duration.zero);
    f.queue.remove(id as String);
    expect((await f.call('send', fields: fields))['body']['task']['removed'], true);
    expect((await f.call('get', fields: {'transferId': id}))['status'], 404);
    expect(f.enqueues, 1);
  });

  test('scan requests coalesce and do not accept remotely supplied networks', () async {
    expect((await f.call('scan'))['body']['coalesced'], false);
    expect((await f.call('scan'))['body']['coalesced'], true);
    expect(f.scans, 1);
    expect((await f.call('scan', fields: {'subnet': '0.0.0.0/0'}))['status'], 400);
  });

  test('claim denial, empty selections, bad channels and request shape never start transfers', () async {
    final fields = await f.sendFields();
    expect((await f.call('send', fields: fields, claim: () async => false))['status'], 503);
    expect((await f.call('send', fields: {...fields, 'channelId': uuid.v4()}))['status'], 404);
    expect((await f.call('send', fields: {...fields, 'path': '/private/file'}))['status'], 400);
    f.selection = [];
    final empty = await f.sendFields();
    expect((await f.call('send', fields: empty))['body']['error']['code'], 'empty_selection');
    expect(f.enqueues, 0);
  });

  test('task descriptors redact raw queue errors and local file fields', () async {
    final id = await f.send();
    f.executions[id]!.completeError(StateError('/private/secret password TOKEN'));
    await Future<void>.delayed(Duration.zero);
    final response = await f.call('get', fields: {'transferId': id});
    expect(response['body']['task']['status'], 'failed');
    expect(response['body']['task']['bytesPerSecond'], 0);
    expect(jsonEncode(response), isNot(contains('private')));
    expect(jsonEncode(response), isNot(contains('TOKEN')));
  });
  test('device and multibyte selection manifests remain within the wire budget with explicit truncation', () async {
    f.devices = List.generate(
      512,
      (index) => peer.copyWith(
        fingerprint: 'peer-$index',
        channels: [
          for (var port = 10000; port < 10032; port++) HttpChannel(host: '2001:db8:abcd:1234:5678:abcd:1234:5678', port: port, https: true),
        ],
      ),
    );
    final listed = await f.call('devices');
    expect(listed['status'], 200);
    expect(listed['body']['truncated'], true);
    expect(utf8.encode(jsonEncode(listed)).length, lessThan(250 * 1024));
    final longName = List.filled(1024, '文').join();
    f.selection = List.generate(100, (_) => file(longName));
    final selected = await f.call('selection');
    expect(selected['status'], 200);
    expect(selected['body']['totalCount'], 100);
    expect(selected['body']['truncated'], false);
    expect(utf8.encode(jsonEncode(selected)).length, lessThan(250 * 1024));
    for (final entry in selected['body']['files'] as List) {
      expect(utf8.encode(entry['name'] as String).length, lessThanOrEqualTo(1024));
    }
  });

  test('existing native queue capacity rejects API work without allocating a receipt', () async {
    for (var index = 0; index < 128; index++) {
      f.queue.enqueue(peer, [file()]);
    }
    final fields = await f.sendFields();
    final response = await f.call('send', fields: fields);
    expect(response['status'], 429);
    expect(response['body']['error']['code'], 'transfer_queue_full');
    expect(f.enqueues, 0);
    f.queue.cancel(f.jobs.last.id);
    expect((await f.call('send', fields: fields))['status'], 202);
    expect(f.enqueues, 1);
  });
  test('device list exposes async scan running, redacted failure and successful recovery', () async {
    expect((await f.call('devices'))['body']['scanState'], 'idle');
    await f.call('scan');
    expect((await f.call('devices'))['body']['scanState'], 'running');
    f.scanGate.completeError(StateError('/private/secret networkdetails'));
    await Future<void>.delayed(Duration.zero);
    final failed = await f.call('devices');
    expect(failed['body']['scanState'], 'failed');
    expect(jsonEncode(failed), isNot(contains('networkdetails')));
    f.now = f.now.add(const Duration(seconds: 6));
    f.scanGate = Completer<void>();
    expect((await f.call('scan'))['body']['coalesced'], false);
    expect((await f.call('devices'))['body']['scanState'], 'running');
    f.scanGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect((await f.call('devices'))['body']['scanState'], 'idle');
  });
  test('labels truncate UTF-8 on whole rune boundaries and repair malformed UTF-16', () async {
    final emoji = List.filled(1024, '🟢').join();
    f.selection = [file('文$emoji'), file('broken${String.fromCharCode(0xd800)}name')];
    f.devices = [peer.copyWith(alias: '文$emoji')];
    final selected = await f.call('selection');
    final listed = await f.call('devices');
    expect(selected['status'], 200);
    expect(listed['status'], 200);
    final name = selected['body']['files'][0]['name'] as String;
    final alias = listed['body']['devices'][0]['alias'] as String;
    expect(utf8.encode(name).length, lessThanOrEqualTo(1024));
    expect(utf8.encode(alias).length, lessThanOrEqualTo(120));
    expect(name, startsWith('文'));
    expect(name, endsWith('🟢'));
    expect(name.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff), false);
    expect(utf8.decode(utf8.encode(name)), name);
    expect(selected['body']['files'][1]['name'], 'broken�name');
  });
  test('C1 controls normalize in labels instead of rejecting the host response', () async {
    f.selection = [file('file\u0085\u009fname')];
    f.devices = [peer.copyWith(alias: 'peer\u0080\u0090')];
    expect((await f.call('selection'))['body']['files'][0]['name'], 'file  name');
    expect((await f.call('devices'))['body']['devices'][0]['alias'], 'peer  ');
  });

  test('trusted restored key principals accept existing UUID versions and case without weakening public IDs', () async {
    const restored = 'ABCDEFAB-1111-1111-8111-111111111111';
    final fields = await f.sendFields();
    final sent = await f.call('send', fields: fields, principal: restored);
    expect(sent['status'], 202);
    final id = sent['body']['task']['id'];
    expect((await f.call('get', fields: {'transferId': id}, principal: restored))['status'], 200);
    expect((await f.call('get', fields: {'transferId': id}, principal: restored.toLowerCase()))['status'], 404);
    expect((await f.call('send', fields: {...fields, 'requestId': restored}, principal: restored))['status'], 400);
  });
}
