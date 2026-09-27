import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/api/transfer_management.dart';
import 'package:localsend_app/util/api/workspace_send_capture.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:uuid/uuid.dart';

import 'transfer_management_test.dart' show peer, file;

const _uuid = Uuid();

class _Fixture {
  final principal = _uuid.v4();
  final jobs = <SendJob>[];
  final capturedInputs = <List<Map<String, String>>>[];
  final copyEntered = Completer<void>();
  Completer<void>? copyGate;
  Completer<void>? captureGate;
  bool current = true, authorized = true, failCapture = false, failRelease = false;
  int captures = 0, copies = 0, releases = 0, claims = 0, legacyCaptures = 0;
  late final TransferManagement manager;
  _Fixture({bool documentCapture = true, bool ownedGuard = true}) {
    manager = TransferManagement(
      readDevices: () => [peer],
      readSelection: () => [],
      readJobs: () => jobs,
      enqueue: (_, _, _) => throw StateError('Unowned enqueue forbidden'),
      enqueueOwned: (_, _, _) => throw StateError('Document capture must use guarded handoff'),
      captureWorkspace: (_, _, _) async {
        legacyCaptures++;
        throw StateError('No filesystem fallback');
      },
      captureDocumentWorkspace: !documentCapture
          ? null
          : (_, _, files) async {
              captures++;
              capturedInputs.add(files);
              await captureGate?.future;
              if (failCapture) throw StateError('Provider changed');
              return WorkspaceSendCapture([file('中文 snapshot.txt')], () async {
                releases++;
                if (failRelease) throw StateError('Cleanup retained');
              }, isCurrent: () => current);
            },
      enqueueCaptured: !ownedGuard
          ? null
          : (target, captured, channel, route) async {
              copies++;
              if (!copyEntered.isCompleted) copyEntered.complete();
              await copyGate?.future;
              // This is the callback contract. The real queue's final-commit guard is
              // independently exercised by send_recovery_race_test.dart.
              if (!captured.isCurrent()) throw StateError('Workspace closed during copy');
              final job = SendJob(id: _uuid.v4(), target: target, files: captured.files, selectedChannel: channel, localRoute: route);
              jobs.add(job);
              return job.id;
            },
      cancel: (_) {},
      remove: (_) {},
      scan: () async {},
    );
  }
  Future<Map<String, dynamic>> call(String op, Map<String, Object?> fields) async =>
      jsonDecode(
            await manager.execute(
              request: jsonEncode({
                'operation': 'transfer.$op',
                'principal': principal,
                'workspaces': ['*'],
                ...fields,
              }),
              claim: () async {
                claims++;
                return authorized;
              },
            ),
          )
          as Map<String, dynamic>;
  Future<Map<String, Object?>> intent() async {
    final devices = await call('devices', {});
    return {
      'workspaceId': _uuid.v4(),
      'generation': 3,
      'instanceId': _uuid.v4(),
      'deviceId': devices['body']['devices'][0]['id'],
      'requestId': _uuid.v4(),
      'sourceMode': 'documentSnapshot',
      'files': [
        {'id': _uuid.v4()},
      ],
    };
  }
}

void main() {
  test('document envelope is explicit while legacy filesystem array is unchanged', () {
    final files = [
      {'id': _uuid.v4()},
    ];
    expect(jsonDecode(encodeWorkspaceCaptureSelection(files, documentSnapshot: true)), {'mode': 'documentSnapshot', 'files': files});
    final legacy = [
      {'id': 'eA', 'version': '"${'a' * 64}"'},
    ];
    expect(jsonDecode(encodeWorkspaceCaptureSelection(legacy)), legacy);
  });
  test('document capture hands off once; cleanup failure keeps its receipt and mode-bound idempotency', () async {
    final f = _Fixture()..failRelease = true;
    final intent = await f.intent();
    final first = await f.call('workspaceSend', intent);
    expect(first['status'], 202);
    expect(f.jobs.single.files.single.name, '中文 snapshot.txt');
    final replay = await f.call('workspaceSend', intent);
    expect(replay['body']['task']['id'], first['body']['task']['id']);
    expect(replay['body']['replayed'], true);
    expect((f.captures, f.copies, f.releases, f.legacyCaptures), (1, 1, 1, 0));
    final legacy = {...intent}..remove('sourceMode');
    legacy['files'] = [
      {'id': 'eA', 'version': '"${'a' * 64}"'},
    ];
    expect((await f.call('workspaceSend', legacy))['status'], 409);
    expect(f.legacyCaptures, 0);
  });
  test('invalid document selector is rejected before claim; no URI/path/version or duplicate input', () async {
    final f = _Fixture();
    final intent = await f.intent();
    final id = (intent['files'] as List).single['id'];
    for (final invalid in <Map<String, Object?>>[
      {'sourceMode': 'filesystem'},
      {'sourceMode': null},
      {'sourceMode': true},
      {
        'files': [
          {'id': id, 'version': '"old"'},
        ],
      },
      {
        'files': [
          {'id': 'content://provider/document/1'},
        ],
      },
      {
        'files': [
          {'id': '../path'},
        ],
      },
      {
        'files': [
          {'id': id},
          {'id': id},
        ],
      },
      {'files': []},
      {
        'files': List.generate(129, (_) => {'id': _uuid.v4()}),
      },
    ]) {
      final claims = f.claims;
      expect((await f.call('workspaceSend', {...intent, ...invalid}))['status'], 400);
      expect(f.claims, claims);
    }
    expect(f.captures, 0);
  });
  test('missing document callback or guarded enqueue fails closed, never falls back to filesystem', () async {
    for (final f in [_Fixture(documentCapture: false), _Fixture(ownedGuard: false)]) {
      final result = await f.call('workspaceSend', await f.intent());
      expect(result['status'], 503);
      expect(result['body']['error']['code'], 'workspace_send_unavailable');
      expect((f.captures, f.legacyCaptures, f.copies), (0, 0, 0));
    }
  });
  test('claimed capture may complete after later authorization change; concurrent same request queues once', () async {
    final f = _Fixture()..copyGate = Completer<void>();
    final intent = await f.intent();
    final first = f.call('workspaceSend', intent);
    await f.copyEntered.future;
    final duplicate = f.call('workspaceSend', intent);
    f.authorized = false;
    expect((await f.call('list', {}))['status'], 503);
    f.copyGate!.complete();
    expect((await first)['status'], 202);
    // A new request still requires claim, even if it would replay a receipt.
    expect((await duplicate)['status'], 503);
    f.authorized = true;
    expect((await f.call('workspaceSend', intent))['body']['replayed'], true);
    expect((f.captures, f.copies, f.releases), (1, 1, 1));
  });
  test('workspace closes before handoff: no queue item, private capture is released', () async {
    final f = _Fixture()..current = false;
    final result = await f.call('workspaceSend', await f.intent());
    expect(result['status'], 409);
    expect(result['body']['error']['code'], 'workspace_changed');
    expect((f.captures, f.copies, f.releases, f.jobs.length), (1, 0, 1, 0));
  });
  test('workspace closes during durable copy: final guard rejects and retry has no ghost receipt', () async {
    final f = _Fixture()..copyGate = Completer<void>();
    final intent = await f.intent();
    final pending = f.call('workspaceSend', intent);
    await f.copyEntered.future;
    expect(f.releases, 0);
    f.current = false;
    f.copyGate!.complete();
    expect((await pending)['status'], 503);
    expect((f.jobs.length, f.releases), (0, 1));
    f.current = true;
    f.copyGate = null;
    expect((await f.call('workspaceSend', intent))['status'], 202);
    expect((f.jobs.length, f.captures, f.releases), (1, 2, 2));
  });
  test('failed provider capture never enters native queue and same request can retry', () async {
    final f = _Fixture()..failCapture = true;
    final intent = await f.intent();
    expect((await f.call('workspaceSend', intent))['status'], 503);
    expect(f.copies, 0);
    f.failCapture = false;
    expect((await f.call('workspaceSend', intent))['status'], 202);
    expect(f.jobs.length, 1);
  });
  test('document manifest requires hash, safe unique leaf names, and cleans failed private stages', () async {
    final root = await Directory.systemTemp.createTemp('document-capture-validation-');
    final store = WorkspaceCaptureStore.leaseProbe(root);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    for (final invalid in <Map<String, Object?>>[
      {'sha256': null},
      {'sha256': 'not-a-hash'},
      {'name': 'nested/file'},
      {'name': 'C:drive'},
      {'name': 'bad\nname'},
      {'name': 'x' * 256},
      {'source': '../outside'},
    ]) {
      late String stage;
      await expectLater(
        captureWorkspaceSources(
          store: store,
          fileCount: 1,
          documentSnapshot: true,
          isCurrent: () => true,
          capture: (destination) async {
            stage = destination;
            await File('$destination/source-0').writeAsString('x');
            return jsonEncode({
              'files': [
                {'source': 'source-0', 'name': 'file.txt', 'size': 1, 'sha256': 'a' * 64, ...invalid},
              ],
            });
          },
        ),
        throwsFormatException,
      );
      expect(await Directory(stage).exists(), false);
    }
  });
  test('complete document capture preserves local stage until release and retains live cancellation guard', () async {
    final root = await Directory.systemTemp.createTemp('document-capture-success-');
    final store = WorkspaceCaptureStore.leaseProbe(root);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    var current = true;
    final capture = await captureWorkspaceSources(
      store: store,
      fileCount: 1,
      documentSnapshot: true,
      isCurrent: () => current,
      capture: (destination) async {
        await File('$destination/source-0').writeAsString('原字节');
        return jsonEncode({
          'files': [
            {'source': 'source-0', 'name': '中文.txt', 'size': 9, 'sha256': 'a' * 64},
          ],
        });
      },
    );
    expect(await File(capture.files.single.path!).readAsString(), '原字节');
    expect(capture.isCurrent(), true);
    current = false;
    expect(capture.isCurrent(), false);
    await capture.release();
    expect(await File(capture.files.single.path!).exists(), false);
  });
}
