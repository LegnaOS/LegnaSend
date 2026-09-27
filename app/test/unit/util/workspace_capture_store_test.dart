import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  late Directory root;
  final stores = <WorkspaceCaptureStore>[];
  WorkspaceCaptureStore store() {
    final value = WorkspaceCaptureStore.leaseProbe(root);
    stores.add(value);
    return value;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owned-capture-');
  });
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    await root.delete(recursive: true);
  });
  Future<Directory> orphan({bool marker = true}) async {
    final id = const Uuid().v4();
    final dir = await Directory(p.join(root.path, id)).create();
    if (marker) {
      await File(p.join(dir.path, 'owner.json')).writeAsString(jsonEncode({'format': 'legnasend.workspace-capture.v1', 'id': id, 'count': 2}));
    }
    await File(p.join(dir.path, 'source-0')).writeAsString('part');
    return dir;
  }

  test('startup removes only registered interrupted stages and reports actual bytes', () async {
    final gone = await orphan();
    final unknown = await orphan(marker: false);
    final outside = await File(p.join(root.path, 'user.ls')).writeAsString('keep');
    final value = store();
    await value.initialize();
    expect(await gone.exists(), false);
    expect(await unknown.exists(), true);
    expect(await outside.readAsString(), 'keep');
    expect(value.lastCleanup.removedStages, 1);
    expect(value.lastCleanup.removedFiles, 1);
    expect(value.lastCleanup.unlinkedBytes, 4);
  });
  test('live leases survive cleanup and repeated release only removes its own stage', () async {
    final value = store();
    final lease = await value.create(2);
    await File(p.join(lease.directory.path, 'source-0')).writeAsString('hello');
    final report = await value.cleanup();
    expect(report.active, 1);
    expect(report.removedFiles, 0);
    await lease.release();
    await lease.release();
    expect(await lease.directory.exists(), false);
    expect(value.lastCleanup.unlinkedBytes, 5);
  });
  test('close waits for an active writer and refuses new admissions', () async {
    final value = store();
    final lease = await value.create(1);
    var closed = false;
    final closing = value.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(closed, false);
    await expectLater(value.create(1), throwsStateError);
    await expectLater(store().initialize(), throwsStateError);
    await lease.release();
    await closing;
    expect(closed, true);
    final next = store();
    await next.initialize();
    expect(next.lastCleanup.removedStages, 0);
  });
  test('failed initialization retries on the same store after the other session closes', () async {
    final first = store();
    await first.initialize();
    final waiting = store();
    await expectLater(waiting.initialize(), throwsStateError);
    await first.close();
    await waiting.initialize();
    final stage = await waiting.create(1);
    await stage.release();
  });
  test('unknown files or nested directories retain the entire registered stage', () async {
    final dir = await orphan();
    await File(p.join(dir.path, 'user.txt')).writeAsString('private');
    final nested = await orphan();
    await Directory(p.join(nested.path, 'folder')).create();
    final value = store();
    await value.initialize();
    expect(value.lastCleanup.retained, 2);
    expect(await File(p.join(dir.path, 'source-0')).readAsString(), 'part');
    expect(await nested.exists(), true);
  });
  test('symlink entries and linked root are never followed', () async {
    if (Platform.isWindows) return; // Windows creation privilege is separately validated.
    final dir = await orphan();
    final target = await File(p.join(root.path, 'outside')).writeAsString('safe');
    await Link(p.join(dir.path, 'source-1')).create(target.path);
    final value = store();
    await value.initialize();
    expect(await target.readAsString(), 'safe');
    expect(await dir.exists(), true);
    final link = Link(p.join(root.path, 'linked-root'));
    await link.create(dir.path);
    final other = WorkspaceCaptureStore.leaseProbe(Directory(link.path));
    stores.add(other);
    await expectLater(other.initialize(), throwsStateError);
  });
  test('cleanup is bounded and later calls continue past removed entries', () async {
    final value = store();
    await value.initialize();
    for (var i = 0; i < 3; i++) {
      await orphan();
    }
    final first = await value.cleanup(limit: 1);
    expect(first.examined, 1);
    expect(first.removedStages, 1);
    expect(first.budgetReached, true);
    final second = await value.cleanup(limit: 3);
    expect(second.removedStages, 2);
    expect(second.budgetReached, false);
  });
  test('retained prefixes never starve a registered stage across bounded batches', () async {
    final value = store();
    await value.initialize();
    for (var i = 0; i < 16; i++) {
      await File(p.join(root.path, '0-keep-$i')).writeAsString('user');
    }
    final target = await orphan();
    var examined = 0;
    for (var i = 0; i < 18; i++) {
      final report = await value.cleanup(limit: 1);
      examined += report.examined;
      if (!report.budgetReached) break;
    }
    expect(examined, 17);
    expect(await target.exists(), false);
    expect(await File(p.join(root.path, '0-keep-0')).readAsString(), 'user');
  });
  test('corrupt ownership and modified format never authorize removal', () async {
    final dir = await orphan();
    await File(p.join(dir.path, 'owner.json')).writeAsString('{');
    final other = await orphan();
    await File(p.join(other.path, 'owner.json')).writeAsString(jsonEncode({'format': 'other', 'id': p.basename(other.path), 'count': 2}));
    final value = store();
    await value.initialize();
    expect(value.lastCleanup.failed, 1);
    expect(value.lastCleanup.retained, 1);
    expect(await dir.exists(), true);
    expect(await other.exists(), true);
  });
}
