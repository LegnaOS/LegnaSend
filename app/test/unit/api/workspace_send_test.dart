import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/api/transfer_management.dart';
import 'package:localsend_app/util/api/workspace_send_capture.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:uuid/uuid.dart';

import 'transfer_management_test.dart' show peer, channel, file;

class _ConcurrentWorkspaceFixture {
  final String phase;
  final int limit;
  final gate = Completer<void>();
  final entered = Completer<void>();
  final selection = [file()];
  final jobs = <SendJob>[];
  final canceled = <String>[];
  final principal = const Uuid().v4();
  int captures = 0, ownedCopies = 0, ordinaryEnqueues = 0;
  bool fail = false;
  late final TransferManagement manager;
  _ConcurrentWorkspaceFixture(this.phase, {this.limit = 512}) {
    Future<void> wait(String at) async {
      if (phase != at) return;
      if (!entered.isCompleted) entered.complete();
      await gate.future;
      if (fail) throw StateError('source copy failed');
    }

    String enqueue(target, files, selected) {
      final job = SendJob(id: const Uuid().v4(), target: target, files: files, selectedChannel: selected);
      jobs.add(job);
      return job.id;
    }

    manager = TransferManagement(
      readDevices: () => [peer],
      readSelection: () => selection,
      readJobs: () => jobs,
      enqueue: (target, files, selected) {
        ordinaryEnqueues++;
        return enqueue(target, files, selected);
      },
      enqueueOwned: (target, files, selected) async {
        ownedCopies++;
        await wait('durable');
        return enqueue(target, files, selected);
      },
      captureWorkspace: (id, generation, files) async {
        captures++;
        await wait('capture');
        return WorkspaceSendCapture([file('folder/source.txt')], () async {});
      },
      cancel: (id) {
        canceled.add(id);
        final index = jobs.indexWhere((job) => job.id == id);
        jobs[index] = jobs[index].withStatus(SendJobStatus.canceled);
      },
      remove: (id) => jobs.removeWhere((job) => job.id == id),
      scan: () async {},
      receiptLimit: limit,
    );
  }
  Future<Map<String, dynamic>> call(String operation, Map<String, Object?> fields) async =>
      jsonDecode(
            await manager.execute(
              request: jsonEncode({
                'operation': 'transfer.$operation',
                'principal': principal,
                'workspaces': ['*'],
                ...fields,
              }),
              claim: () async => true,
            ),
          )
          as Map<String, dynamic>;
  Future<Map<String, Object?>> workspaceIntent() async {
    final devices = await call('devices', {});
    return {
      'workspaceId': const Uuid().v4(),
      'generation': 1,
      'instanceId': const Uuid().v4(),
      'deviceId': devices['body']['devices'][0]['id'],
      'requestId': const Uuid().v4(),
      'files': [
        {'id': 'eA', 'version': '"${'a' * 64}"'},
      ],
    };
  }

  Future<Map<String, Object?>> selectionIntent(Object? deviceId, {Object? requestId}) async {
    final selected = await call('selection', {});
    return {'deviceId': deviceId, 'requestId': requestId ?? const Uuid().v4(), 'selectionVersion': selected['body']['selectionVersion']};
  }
}

void main() {
  test('workspace captures use durable enqueue, replay once, and cleanup failure cannot resend', () async {
    var captures = 0, queued = 0, released = 0;
    final jobs = <SendJob>[];
    late TransferManagement manager;
    manager = TransferManagement(
      readDevices: () => [peer],
      readSelection: () => [],
      readJobs: () => jobs,
      enqueue: (_, _, _) => throw StateError('Workspace must not use unowned enqueue'),
      enqueueOwned: (target, files, selected) async {
        queued++;
        final job = SendJob(id: const Uuid().v4(), target: target, files: files, selectedChannel: selected);
        jobs.add(job);
        return job.id;
      },
      captureWorkspace: (id, generation, files) async {
        captures++;
        expect(generation, 3);
        expect(files.single['id'], 'eA');
        return WorkspaceSendCapture([file('nested/original.txt')], () async {
          released++;
          throw StateError('Read-only cleanup failure');
        });
      },
      cancel: (_) {},
      remove: (_) {},
      scan: () async {},
    );
    final principal = const Uuid().v4();
    Future<Map<String, dynamic>> call(String op, Map<String, Object?> fields, {bool allowed = true}) async =>
        jsonDecode(
              await manager.execute(
                request: jsonEncode({
                  'operation': 'transfer.$op',
                  'principal': principal,
                  'workspaces': ['*'],
                  ...fields,
                }),
                claim: () async => allowed,
              ),
            )
            as Map<String, dynamic>;
    final devices = await call('devices', {});
    final intent = <String, Object?>{
      'workspaceId': const Uuid().v4(),
      'generation': 3,
      'instanceId': const Uuid().v4(),
      'deviceId': devices['body']['devices'][0]['id'],
      'requestId': const Uuid().v4(),
      'files': [
        {'id': 'eA', 'version': '"${'a' * 64}"'},
      ],
    };
    expect((await call('workspaceSend', intent, allowed: false))['status'], 503);
    expect(captures, 0);
    final first = await call('workspaceSend', intent);
    expect(first['status'], 202);
    expect(first['body']['replayed'], false);
    final second = await call('workspaceSend', intent);
    expect(second['body']['task']['id'], first['body']['task']['id']);
    expect(second['body']['replayed'], true);
    expect((captures, queued, released), (1, 1, 1));
    expect((await call('workspaceSend', {...intent, 'generation': 4}))['status'], 409);
    expect((await call('workspaceSend', {...intent, 'path': '/arbitrary'}))['status'], 400);
  });
  for (final phase in ['capture', 'durable']) {
    test('workspace $phase I/O leaves reads and cancellation responsive while duplicate intents enqueue once', () async {
      final f = _ConcurrentWorkspaceFixture(phase);
      final intent = await f.workspaceIntent();
      final initial = await f.call('send', await f.selectionIntent(intent['deviceId']));
      final oldId = initial['body']['task']['id'];
      final first = f.call('workspaceSend', intent);
      await f.entered.future.timeout(const Duration(seconds: 2));
      final duplicate = f.call('workspaceSend', intent);
      final cancel = await f.call('cancel', {'transferId': oldId}).timeout(const Duration(seconds: 2));
      expect(cancel['status'], 200);
      expect(f.canceled, [oldId]);
      expect((await f.call('devices', {}).timeout(const Duration(seconds: 2)))['status'], 200);
      expect((await f.call('list', {}).timeout(const Duration(seconds: 2)))['status'], 200);
      final conflict = await f.call('send', await f.selectionIntent(intent['deviceId'], requestId: intent['requestId']));
      expect(conflict['status'], 409);
      expect(conflict['body']['error']['code'], 'idempotency_conflict');
      expect(f.ordinaryEnqueues, 1);
      f.gate.complete();
      final accepted = await first;
      final replayed = await duplicate;
      expect(accepted['status'], 202);
      expect(replayed['body']['replayed'], true);
      expect(replayed['body']['task']['id'], accepted['body']['task']['id']);
      expect((f.captures, f.ownedCopies), (1, 1));
    });
  }

  test('inflight workspace receipts reserve capacity and failed capture releases the reservation', () async {
    final f = _ConcurrentWorkspaceFixture('capture', limit: 1);
    final intent = await f.workspaceIntent();
    final pending = f.call('workspaceSend', intent);
    await f.entered.future.timeout(const Duration(seconds: 2));
    final ordinary = await f.selectionIntent(intent['deviceId']);
    expect((await f.call('send', ordinary))['status'], 429);
    f.fail = true;
    f.gate.complete();
    expect((await pending)['status'], 503);
    expect((await f.call('send', ordinary))['status'], 202);
    expect(f.ownedCopies, 0);
  });

  test('durable captured local files survive original deletion and preserve relative names', () async {
    final temp = await Directory.systemTemp.createTemp('workspace-owned-test-');
    final source = await File('${temp.path}/input').writeAsString('raw original bytes');
    final store = SendRecoveryStore(Directory('${temp.path}/journal'));
    try {
      final selected = file('folder/中文.txt').copyWith(path: source.path, bytes: null, size: 18);
      final saved = await store.saveManifest(
        SendJob(id: const Uuid().v4(), target: peer, files: [selected], selectedChannel: channel),
        copyLocalSources: true,
      );
      expect(saved.files.single.path, isNot(source.path));
      expect(saved.files.single.name, 'folder/中文.txt');
      await source.delete();
      expect(await File(saved.files.single.path!).readAsString(), 'raw original bytes');
      final restored = await store.load();
      expect(restored.single.files.single.name, 'folder/中文.txt');
      await store.validateRemaining(restored.single);
    } finally {
      await temp.delete(recursive: true);
    }
  });
  test('capture rejects unsafe bridge names and removes its private partial stage', () async {
    final root = await Directory.systemTemp.createTemp('capture-test-');
    final store = WorkspaceCaptureStore.leaseProbe(root);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    String? path;
    await expectLater(
      captureWorkspaceSources(
        store: store,
        fileCount: 1,
        isCurrent: () => true,
        capture: (destination) async {
          path = destination;
          await File('$destination/source-0').writeAsString('x');
          return jsonEncode({
            'files': [
              {'name': '../escape', 'source': 'source-0', 'size': 1},
            ],
          });
        },
      ),
      throwsFormatException,
    );
    expect(await Directory(path!).exists(), false);
  });
}
