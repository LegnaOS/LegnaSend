import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/util/api/host_native_tasks.dart';

void main() {
  late HostNativeTasks manager;
  late List<HostNativeTask> tasks;
  late List<(String, String)> controls;
  late int generation;
  HostNativeTask task(
    String id, {
    TransferDirection direction = TransferDirection.send,
    TransferPhase phase = TransferPhase.transferring,
    Object revision = 1,
    int bytes = 3,
  }) => HostNativeTask(
    activity: TransferActivity(
      id: id,
      direction: direction,
      phase: phase,
      peer: '/private-peer',
      files: [TransferActivityFile('/private/file', 100, bytes)],
    ),
    controlRevision: revision,
    bytesPerSecond: 75,
    actions: phase == TransferPhase.waiting && direction == TransferDirection.receive
        ? ['accept', 'reject']
        : phase == TransferPhase.succeeded
        ? ['remove']
        : ['cancel'],
  );
  Future<Map<String, dynamic>> call(
    String op, {
    Map<String, Object>? change,
    String? id,
    Future<bool> Function()? claim,
    String? principal = 'key',
    List<String> workspaces = const ['*'],
  }) async =>
      jsonDecode(
            await manager.execute(
              request: jsonEncode({
                'operation': 'nativeTasks.$op',
                'principal': principal,
                'workspaces': workspaces,
                'change': ?change,
                'taskId': ?id,
              }),
              claim: claim ?? () async => true,
            ),
          )
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> list() async => (await call('list'))['body'] as Map<String, dynamic>;
  Map<String, Object> change(Map<String, dynamic> snapshot, String action, {int index = 0}) => {
    'epoch': snapshot['epoch'] as String,
    'version': snapshot['tasks'][index]['version'] as String,
    'action': action,
  };
  setUp(() {
    tasks = [task('send'), task('receive', direction: TransferDirection.receive, phase: TransferPhase.waiting)];
    controls = [];
    generation = 1;
    manager = HostNativeTasks(
      readGeneration: () => generation,
      readTasks: () => tasks,
      control: (task, action) async {
        controls.add((task.activity.id, action));
      },
    );
  });
  test('global snapshot has opaque identities and real counters, never paths or peer labels', () async {
    final snapshot = await list();
    expect(snapshot['tasks'], hasLength(2));
    expect(snapshot['tasks'][0]['bytesPerSecond'], 75);
    expect(snapshot['tasks'][0]['transferredBytes'], 3);
    expect(jsonEncode(snapshot), isNot(contains('/private')));
    expect(snapshot['tasks'][0]['id'], isNot('send'));
    expect(snapshot['tasks'][1]['actions'], ['accept', 'reject']);
  });
  test('progress-only updates preserve control revision while phase changes invalidate it', () async {
    final a = await list();
    tasks = [task('send', bytes: 70), tasks.last];
    final b = await list();
    expect(b['tasks'][0]['version'], a['tasks'][0]['version']);
    tasks = [task('send', revision: 2, phase: TransferPhase.succeeded), tasks.last];
    expect((await call('control', id: a['tasks'][0]['id'] as String, change: change(a, 'cancel')))['status'], 409);
    expect(controls, isEmpty);
  });
  test('claim gap checks task replacement, local receive changes and server restart', () async {
    for (final mode in ['replace', 'receive', 'restart']) {
      final a = await list();
      final index = mode == 'receive' ? 1 : 0;
      final result = await call(
        'control',
        id: a['tasks'][index]['id'] as String,
        change: change(a, index == 1 ? 'accept' : 'cancel', index: index),
        claim: () async {
          if (mode == 'restart') {
            generation++;
          } else if (mode == 'receive') {
            tasks = [tasks.first, task('receive', direction: TransferDirection.receive, phase: TransferPhase.waiting, revision: 99)];
          } else {
            tasks = [task('replacement'), tasks.last];
          }
          return true;
        },
      );
      expect(result['status'], 409);
      expect(controls, isEmpty);
    }
  });
  test('independent send cancel does not affect receive and consumed version cannot repeat', () async {
    final a = await list();
    final id = a['tasks'][0]['id'] as String;
    final body = change(a, 'cancel');
    expect((await call('control', id: id, change: body))['status'], 200);
    expect(controls, [('send', 'cancel')]);
    expect((await call('control', id: id, change: body))['status'], 409);
    expect(controls, hasLength(1));
    expect((await list())['tasks'][1]['version'], a['tasks'][1]['version']);
  });
  test('receive approve/reject and terminal removal invoke exact selected task', () async {
    for (final action in ['accept', 'reject']) {
      final a = await list();
      expect((await call('control', id: a['tasks'][1]['id'] as String, change: change(a, action, index: 1)))['status'], 200);
    }
    tasks = [task('finished', phase: TransferPhase.succeeded)];
    final a = await list();
    expect((await call('control', id: a['tasks'][0]['id'] as String, change: change(a, 'remove')))['status'], 200);
    expect(controls, [('receive', 'accept'), ('receive', 'reject'), ('finished', 'remove')]);
    expect(a['tasks'][0]['bytesPerSecond'], 0);
  });
  test('missing global key, unsupported action and expired claim produce no effects', () async {
    expect((await call('list', principal: null))['status'], 403);
    expect((await call('list', workspaces: ['workspace']))['status'], 403);
    final a = await list();
    final id = a['tasks'][0]['id'] as String;
    expect((await call('control', id: id, change: change(a, 'pause')))['status'], 400);
    expect((await call('control', id: id, change: change(a, 'remove')))['status'], 409);
    expect((await call('control', id: id, change: change(a, 'cancel'), claim: () async => false))['status'], 409);
    expect(controls, isEmpty);
  });
  test('bounded output caps 512 tasks and versions do not reveal another epoch', () async {
    tasks = List.generate(600, (i) => task('$i'));
    final a = await list();
    expect(a['tasks'], hasLength(512));
    expect(a['truncated'], true);
    generation++;
    final b = await list();
    expect(b['epoch'], isNot(a['epoch']));
    expect(b['tasks'][0]['id'], isNot(a['tasks'][0]['id']));
  });
  test('pending mobile accept leaves task reads and opposite cancellation available', () async {
    final entered = Completer<void>(), permission = Completer<void>();
    manager = HostNativeTasks(
      readGeneration: () => generation,
      readTasks: () => tasks,
      control: (taskValue, action) async {
        controls.add((taskValue.activity.id, action));
        if (action == 'accept') {
          tasks = [tasks.first, task('receive', direction: TransferDirection.receive, phase: TransferPhase.transferring, revision: 2)];
          entered.complete();
          await permission.future;
        }
      },
    );
    final a = await list();
    final accepting = call('control', id: a['tasks'][1]['id'] as String, change: change(a, 'accept', index: 1));
    await entered.future;
    try {
      final b = await list().timeout(const Duration(seconds: 1));
      expect(b['tasks'][1]['phase'], 'transferring');
      expect(
        (await call('control', id: b['tasks'][0]['id'] as String, change: change(b, 'cancel')).timeout(const Duration(seconds: 1)))['status'],
        200,
      );
      expect(controls, [('receive', 'accept'), ('send', 'cancel')]);
    } finally {
      permission.complete();
    }
    expect((await accepting)['status'], 200);
  });
  test('concurrent claims for one version dispatch exactly once without a global lock', () async {
    final a = await list();
    final release = Completer<void>();
    var claims = 0;
    Future<bool> claim() async {
      claims++;
      if (claims == 2) release.complete();
      await release.future;
      return true;
    }

    final result = await Future.wait([
      call('control', id: a['tasks'][0]['id'] as String, change: change(a, 'cancel'), claim: claim),
      call('control', id: a['tasks'][0]['id'] as String, change: change(a, 'cancel'), claim: claim),
    ]).timeout(const Duration(seconds: 1));
    expect(result.map((r) => r['status']).toList()..sort(), [200, 409]);
    expect(controls, [('send', 'cancel')]);
  });
}
