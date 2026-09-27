import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory root;
  late SendRecoveryStore store;
  const channel = HttpChannel(host: 'fe80::abcd%3', port: 53317, https: false);
  final device = Device.empty.copyWith(ip: channel.host, port: channel.port, version: '2.2', alias: '设备 🍃', channels: [channel]);
  CrossFile source({String name = '你好/文件.txt', String? path, List<int>? bytes, int? size}) => CrossFile(
    name: name,
    fileType: FileType.text,
    size: size ?? bytes!.length,
    path: path,
    bytes: bytes,
    thumbnail: null,
    asset: null,
    lastModified: null,
    lastAccessed: null,
  );
  SendJob job(List<CrossFile> files, {String id = '重启任务 🍃'}) => SendJob(id: id, target: device, selectedChannel: channel, files: files);
  Future<File> external(String text, {String name = '外部.txt'}) => File(p.join(temp.path, name)).writeAsString(text, flush: true);
  Future<Directory> owned() async => (await root.list().toList()).whereType<Directory>().single;
  Future<Map<String, dynamic>> readRecord(String name) async =>
      jsonDecode(await File(p.join((await owned()).path, name)).readAsString()) as Map<String, dynamic>;
  Future<void> writeRecord(String name, Map<String, dynamic> record) async =>
      File(p.join((await owned()).path, name)).writeAsString(jsonEncode(record));
  Matcher code(String value) => isA<SendRecoveryException>().having((e) => e.code, 'code', value);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legnasend-recovery-');
    root = Directory(p.join(temp.path, '恢复任务'));
    store = SendRecoveryStore(root);
  });
  tearDown(() async {
    await store.releaseSession();
    await temp.delete(recursive: true);
  });

  test('old manifests migrate stable per-file keys before exposing recovery identities', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    final manifest = await readRecord('manifest.json');
    for (final record in manifest['files'] as List) {
      (record as Map).remove('resumeKey');
    }
    await writeRecord('manifest.json', manifest);
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.resumeKeysPersisted, isTrue);
    expect(restored.resumeKeys, hasLength(2));
    expect(restored.resumeKeys.toSet(), hasLength(2));
    final persisted = await readRecord('manifest.json');
    expect([for (final record in persisted['files'] as List) record['resumeKey']], restored.resumeKeys);
    expect((await SendRecoveryStore(root).load()).single.resumeKeys, restored.resumeKeys);
    expect(restored.resumeKeys, isNot(saved.resumeKeys));
  });

  test('new selection gets new keys while explicit retry preserves exact source keys across restart', () async {
    final first = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ], id: 'first'),
    );
    final retried = await store.saveManifest(
      SendJob(id: 'retry', target: device, selectedChannel: channel, files: [first.files[1]], resumeKeys: [first.resumeKeys[1]]),
    );
    final fresh = await store.saveManifest(
      job([
        source(bytes: [2]),
      ], id: 'fresh'),
    );
    expect(retried.resumeKeys.single, first.resumeKeys[1]);
    expect(fresh.resumeKeys.single, isNot(first.resumeKeys[1]));
    final loaded = await SendRecoveryStore(root).load();
    expect(loaded.singleWhere((job) => job.id == 'retry').resumeKeys, retried.resumeKeys);
  });

  test('corrupt or duplicate persisted recovery keys do not become advertised', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    final manifest = await readRecord('manifest.json');
    final records = manifest['files'] as List;
    records[1]['resumeKey'] = records[0]['resumeKey'];
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    expect(store.issues.single, contains('invalidRecord'));
  });

  test('failed legacy migration does not write or expose a partial generated key set', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    final manifest = await readRecord('manifest.json');
    final records = manifest['files'] as List;
    (records[0] as Map).remove('resumeKey');
    records[1]['resumeKey'] = 'corrupt';
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    expect((await readRecord('manifest.json'))['files'], records);
  });

  test('fresh instance restores Unicode paths fixed route and completion indices without sessions', () async {
    final file = await external('hello');
    final original = job([source(path: file.path, size: 5), source(bytes: utf8.encode('🌿'))]);
    final snapshot = await store.saveManifest(original);
    expect(snapshot.files[1].bytes, utf8.encode('🌿'));
    // Active messages retain the normal native preview; restart reads metadata only.
    expect(await File(snapshot.files[1].path!).readAsBytes(), utf8.encode('🌿'));
    await store.saveProgress(original.id, completed: {0}, skipped: {});
    final fresh = SendRecoveryStore(root);
    final restored = (await fresh.load()).single;
    expect(fresh.issues, isEmpty);
    expect(restored.restored, isTrue);
    expect(restored.status, SendJobStatus.failed);
    expect(restored.completedIndices, {0});
    expect(restored.files[0].path, file.path);
    expect(restored.files[1].name, '你好/文件.txt');
    expect(restored.files[1].bytes, isNull);
    expect(restored.selectedChannel!.host, channel.host);
    expect(restored.selectedChannel!.https, isFalse);
    final text = await File(p.join((await owned()).path, 'manifest.json')).readAsString();
    for (final forbidden in ['sessionId', 'token', 'pin', 'privateKey']) {
      expect(text, isNot(contains(forbidden)));
    }
    await fresh.validateRemaining(restored);
  });

  test('memory sources larger than 32 MiB stream to persistent files', () async {
    final bytes = Uint8List(33 * 1024 * 1024)..[0] = 73;
    bytes[bytes.length - 1] = 91;
    final snapshot = await store.saveManifest(job([source(bytes: bytes)]));
    final file = File(snapshot.files.single.path!);
    expect(await file.length(), bytes.length);
    final reader = await file.open();
    expect(await reader.readByte(), 73);
    await reader.setPosition(bytes.length - 1);
    expect(await reader.readByte(), 91);
    await reader.close();
  });

  test('retry copies owned sources before old history is deleted', () async {
    final first = await store.saveManifest(
      job([
        source(bytes: [1, 2, 3]),
      ]),
    );
    final restoredFiles = (await store.load()).single.files;
    final next = await store.saveManifest(job(restoredFiles, id: 'retry'));
    expect(next.files.single.path, isNot(first.files.single.path));
    await store.remove(first.id);
    expect(await File(next.files.single.path!).readAsBytes(), [1, 2, 3]);
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.id, 'retry');
    await store.validateRemaining(restored);
  });

  test('repeat save does not rewrite immutable source or manifest', () async {
    final first = await store.saveManifest(
      job([
        source(bytes: [1, 2, 3]),
      ]),
    );
    final manifest = File(p.join((await owned()).path, 'manifest.json'));
    final original = await manifest.readAsString();
    final next = await store.saveManifest(
      job([
        source(bytes: [9, 9, 9]),
      ]),
    );
    expect(next.files.single.path, first.files.single.path);
    expect(await File(next.files.single.path!).readAsBytes(), [1, 2, 3]);
    expect(await manifest.readAsString(), original);
  });

  test('progress stays independent and invalid replacement preserves previous record', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    final manifest = File(p.join((await owned()).path, 'manifest.json'));
    final before = await manifest.readAsBytes();
    final stat = await manifest.stat();
    await store.saveProgress(saved.id, completed: {0}, skipped: {});
    await expectLater(store.saveProgress(saved.id, completed: {0}, skipped: {0}), throwsA(code('invalidRecord')));
    expect((await store.load()).single.completedIndices, {0});
    expect(await manifest.readAsBytes(), before);
    expect((await manifest.stat()).modified, stat.modified);
  });

  test('writes serialize across multiple store instances without losing latest progress', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    await Future.wait([
      store.saveProgress(saved.id, completed: {0}, skipped: {}),
      SendRecoveryStore(root).saveProgress(saved.id, completed: {0, 1}, skipped: {}),
    ]);
    final restored = (await store.load()).single;
    expect(restored.completedIndices, {0, 1});
    expect(restored.status, SendJobStatus.succeeded);
    expect((await (await owned()).list().toList()).any((e) => e.path.contains('.writing-')), isFalse);
  });

  test('startup never checks missing external source and explicit validation reports it', () async {
    final file = await external('abc');
    await store.saveManifest(job([source(path: file.path, size: 3)]));
    await file.delete();
    final restored = (await store.load()).single;
    expect(restored.recoveryIssue, isNull);
    await expectLater(store.validateRemaining(restored), throwsA(code('sourceMissing')));
  });

  test('length and same-length modified source changes are rejected on explicit continue', () async {
    final file = await external('abc');
    await store.saveManifest(job([source(path: file.path, size: 3)]));
    final restored = (await store.load()).single;
    await file.writeAsString('longer');
    await expectLater(store.validateRemaining(restored), throwsA(code('sourceChanged')));
    await file.writeAsString('xyz');
    await file.setLastModified(DateTime(2000));
    await expectLater(store.validateRemaining(restored), throwsA(code('sourceChanged')));
  });

  test('completed or explicitly skipped sources need not remain on disk', () async {
    final file = await external('abc');
    final saved = await store.saveManifest(
      job([
        source(path: file.path, size: 3),
        source(bytes: [4]),
      ]),
    );
    await store.saveProgress(saved.id, completed: {0}, skipped: {1});
    await file.delete();
    await File(saved.files[1].path!).delete();
    final restored = (await store.load()).single;
    expect(restored.status, SendJobStatus.succeeded);
    await store.validateRemaining(restored);
  });

  test('SAF sources retain URI and display permission boundary without treating URI as file', () async {
    await store.saveManifest(job([source(path: 'content://documents/tree/授权', size: 123)]));
    final restored = (await store.load()).single;
    expect(restored.files.single.path, 'content://documents/tree/授权');
    expect(restored.recoveryIssue, 'sourcePermission');
    await expectLater(store.validateRemaining(restored), throwsA(code('sourcePermission')));
  });

  test('malformed metadata is retained and surfaced while healthy jobs still load', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
      ], id: 'broken'),
    );
    await File(p.join((await owned()).path, 'manifest.json')).writeAsString('{broken');
    await store.saveManifest(
      job([
        source(bytes: [2]),
      ], id: 'healthy'),
    );
    final restored = await store.load();
    expect(restored.single.id, 'healthy');
    expect(store.issues, hasLength(1));
    expect((await root.list().toList()).whereType<Directory>(), hasLength(2));
    await store.load();
    expect(store.issues, hasLength(1));
  });

  test('malformed progress indices never silently resend confirmed results', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    await writeRecord('progress.json', {
      'version': 1,
      'id': '重启任务 🍃',
      'completed': [0, 0],
      'skipped': [],
    });
    expect(await store.load(), isEmpty);
    expect(store.issues.single, contains('invalidRecord'));
  });

  test('invalid versions sizes and directory traversal are rejected without deleting records', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    final manifest = await readRecord('manifest.json');
    manifest['version'] = 999;
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    manifest['version'] = 1;
    final record = (manifest['files'] as List).single as Map<String, dynamic>;
    record['size'] = -1;
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    record['size'] = 1;
    record['path'] = '../../user-file';
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    expect(store.issues.single, contains('unsafePath'));
  });

  test('root and source symlinks are rejected and targets preserved', () async {
    final file = await external('original');
    final link = Link(p.join(temp.path, 'alias'));
    await link.create(file.path);
    await expectLater(store.saveManifest(job([source(path: link.path, size: 8)])), throwsA(code('unsafePath')));
    final rootAlias = Link(p.join(temp.path, 'root-alias'));
    await rootAlias.create(root.path);
    await expectLater(SendRecoveryStore(Directory(rootAlias.path)).load(), throwsA(code('unsafePath')));
    expect(await file.readAsString(), 'original');
  });

  test('replaced owned source symlink never escapes validation or deletion', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    final outside = await external('keep me');
    final sourceFile = File(saved.files.single.path!);
    await sourceFile.delete();
    await Link(sourceFile.path).create(outside.path);
    final restored = (await store.load()).single;
    await expectLater(store.validateRemaining(restored), throwsA(code('unsafePath')));
    await expectLater(store.remove(saved.id), throwsA(code('unsafePath')));
    expect(await outside.readAsString(), 'keep me');
  });

  test('remove touches only registered private files and refuses unknown directory contents', () async {
    final file = await external('original');
    final saved = await store.saveManifest(
      job([
        source(path: file.path, size: 8),
        source(bytes: [3]),
      ]),
    );
    final unknown = await File(p.join((await owned()).path, 'user-notes.txt')).writeAsString('keep');
    await expectLater(store.remove(saved.id), throwsA(code('unsafePath')));
    expect(await unknown.readAsString(), 'keep');
    expect(await File(saved.files[1].path!).exists(), isTrue);
    await unknown.delete();
    await store.remove(saved.id);
    expect(await file.readAsString(), 'original');
    expect((await root.list().toList()).map((e) => p.basename(e.path)), ['.send-recovery.lock']);
  });
  test('non-integer version is rejected instead of coerced', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    final manifest = await readRecord('manifest.json');
    manifest['version'] = 1.0;
    await writeRecord('manifest.json', manifest);
    expect(await store.load(), isEmpty);
    expect(store.issues.single, contains('invalidRecord'));
  });

  test('replaced task directory symlink is neither loaded nor followed for removal', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    final directory = await owned();
    final backup = await directory.rename(p.join(temp.path, 'backup'));
    await Link(directory.path).create(backup.path);
    expect(await store.load(), isEmpty);
    expect(store.issues.single, contains('unsafePath'));
    await expectLater(store.remove(saved.id), throwsA(code('unsafePath')));
    expect(await File(p.join(backup.path, 'source-0')).readAsBytes(), [1]);
  });

  test('failed manifest capture keeps recoverable ownership and cleanup never touches source', () async {
    final outside = await external('original');
    await expectLater(
      store.saveManifest(
        job([
          source(bytes: [1, 2]),
          source(path: outside.path, size: 99),
        ]),
      ),
      throwsA(code('sourceChanged')),
    );
    expect(await store.load(), isEmpty);
    expect(store.issues, hasLength(1));
    await store.remove('重启任务 🍃');
    expect((await root.list().toList()).map((e) => p.basename(e.path)), ['.send-recovery.lock']);
    expect(await outside.readAsString(), 'original');
  });

  test('5000-file manifest remains immutable while independent progress advances', () async {
    final outside = await external('x');
    final files = List.generate(5000, (i) => source(path: outside.path, name: '目录/文件-$i.txt', size: 1));
    final saved = await store.saveManifest(job(files));
    final manifest = File(p.join((await owned()).path, 'manifest.json'));
    final before = await manifest.stat();
    await store.saveProgress(saved.id, completed: Set.from(List.generate(4999, (i) => i)), skipped: {});
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.files, hasLength(5000));
    expect(restored.completedIndices, hasLength(4999));
    expect((await manifest.stat()).modified, before.modified);
    await store.validateRemaining(restored);
  });
  test('automatic routing remains automatic across fresh store recovery', () async {
    final automatic = SendJob(
      id: 'automatic',
      target: device,
      files: [
        source(bytes: [7, 8]),
      ],
    );
    final saved = await store.saveManifest(automatic);
    expect(saved.selectedChannel, isNull);
    final record = await readRecord('manifest.json');
    expect(record.containsKey('channel'), isTrue);
    expect(record['channel'], isNull);
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.selectedChannel, isNull);
    expect(restored.target.fingerprint, device.fingerprint);
    expect(restored.target.channels.single, isA<HttpChannel>());
    await store.validateRemaining(restored);
  });

  test('journal operations wait for an exclusive lock held by another process', () async {
    await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    final script = await File(p.join(temp.path, 'hold_lock.dart')).writeAsString(r"""
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  await file.lock(FileLock.blockingExclusive);
  stdout.writeln('READY');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  await file.close();
}
""");
    final dart = p.join(
      Directory.current.path,
      '..',
      '.fvm',
      'flutter_sdk',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    final child = await Process.start(dart, [script.path, p.join(root.path, '.send-recovery.lock')]);
    try {
      expect(await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 15)), 'READY');
      var completed = false;
      final loading = store.load().then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(completed, isFalse);
      child.stdin.writeln('release');
      await child.stdin.flush();
      expect(await child.exitCode.timeout(const Duration(seconds: 15)), 0);
      expect(await loading.timeout(const Duration(seconds: 15)), hasLength(1));
      expect(store.issues, isEmpty);
    } finally {
      child.kill();
      await child.stdin.close();
    }
  });

  test('symbolic-link journal lock is rejected without touching its target', () async {
    await root.create();
    final outside = await external('keep');
    await Link(p.join(root.path, '.send-recovery.lock')).create(outside.path);
    await expectLater(store.load(), throwsA(code('unsafePath')));
    expect(await outside.readAsString(), 'keep');
  });
  test('only one live store session may restore jobs, then ownership can transfer', () async {
    final other = SendRecoveryStore(root);
    await Future.wait([store.claimSession(), store.claimSession()]);
    await expectLater(other.claimSession(), throwsA(code('busy')));
    await store.saveManifest(
      job([
        source(bytes: [9]),
      ]),
    );
    expect((await store.load()).single.id, '重启任务 🍃');
    expect(store.issues, isEmpty);
    await store.releaseSession();
    await other.claimSession();
    await expectLater(store.claimSession(), throwsA(code('busy')));
    await other.releaseSession();
    await store.claimSession();
    await store.releaseSession();
    await store.releaseSession();
  });

  test('another process session claim fails promptly and succeeds after its owner exits', () async {
    await root.create();
    final script = await File(p.join(temp.path, 'hold_session.dart')).writeAsString(r"""
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('READY');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  await file.close();
}
""");
    final dart = p.join(
      Directory.current.path,
      '..',
      '.fvm',
      'flutter_sdk',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    final child = await Process.start(dart, [script.path, p.join(root.path, '.send-recovery.session.lock')]);
    try {
      expect(await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 15)), 'READY');
      await expectLater(store.claimSession().timeout(const Duration(seconds: 2)), throwsA(code('busy')));
      child.stdin.writeln('release');
      await child.stdin.flush();
      expect(await child.exitCode.timeout(const Duration(seconds: 15)), 0);
      await store.claimSession();
      await store.saveManifest(
        job([
          source(bytes: [1]),
        ]),
      );
      expect(await store.load(), hasLength(1));
      expect(store.issues, isEmpty);
      await store.releaseSession();
    } finally {
      child.kill();
      await child.stdin.close();
    }
  });
  test('deliberately stale checkpoints arriving after newer confirmation never regress completed or skipped outcomes', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
        source(bytes: [3]),
      ]),
    );
    final staleStore = SendRecoveryStore(root);
    await store.saveProgress(saved.id, completed: {0, 1}, skipped: {2});
    // Force the harmful order rather than depending on disk scheduler timing.
    await staleStore.saveProgress(saved.id, completed: {0}, skipped: {});
    await SendRecoveryStore(root).saveProgress(saved.id, completed: {}, skipped: {});
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.completedIndices, {0, 1});
    expect(restored.skippedIndices, {2});
    expect(restored.status, SendJobStatus.succeeded);
  });

  test('independent partial checkpoint contributions merge atomically across stores', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
        source(bytes: [3]),
      ]),
    );
    await Future.wait([
      store.saveProgress(saved.id, completed: {0}, skipped: {}),
      SendRecoveryStore(root).saveProgress(saved.id, completed: {1}, skipped: {}),
      SendRecoveryStore(root).saveProgress(saved.id, completed: {}, skipped: {2}),
    ]);
    final restored = (await SendRecoveryStore(root).load()).single;
    expect(restored.completedIndices, {0, 1});
    expect(restored.skippedIndices, {2});
    expect(restored.status, SendJobStatus.succeeded);
  });

  test('checkpoint input is snapshotted synchronously before asynchronous root resolution', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    final completed = <int>{0};
    final skipped = <int>{1};
    final write = store.saveProgress(saved.id, completed: completed, skipped: skipped);
    completed.clear();
    skipped.clear();
    await write;
    final restored = (await store.load()).single;
    expect(restored.completedIndices, {0});
    expect(restored.skippedIndices, {1});
  });

  test('conflicting late outcomes reject the write without changing the previous checkpoint', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
        source(bytes: [2]),
      ]),
    );
    await store.saveProgress(saved.id, completed: {0}, skipped: {1});
    final before = await readRecord('progress.json');
    await expectLater(SendRecoveryStore(root).saveProgress(saved.id, completed: {1}, skipped: {}), throwsA(code('invalidRecord')));
    await expectLater(SendRecoveryStore(root).saveProgress(saved.id, completed: {}, skipped: {0}), throwsA(code('invalidRecord')));
    expect(await readRecord('progress.json'), before);
  });

  test('corrupted existing checkpoint is preserved rather than overwritten by later acknowledgements', () async {
    final saved = await store.saveManifest(
      job([
        source(bytes: [1]),
      ]),
    );
    await writeRecord('progress.json', {
      'version': 1,
      'id': saved.id,
      'completed': [99],
      'skipped': [],
    });
    final before = await readRecord('progress.json');
    await expectLater(store.saveProgress(saved.id, completed: {0}, skipped: {}), throwsA(code('invalidRecord')));
    expect(await readRecord('progress.json'), before);
    expect(await store.load(), isEmpty);
    expect(store.issues, hasLength(1));
  });
}
