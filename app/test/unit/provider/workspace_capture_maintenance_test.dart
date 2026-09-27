import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

class _Store extends WorkspaceCaptureStoreNotifier {
  final WorkspaceCaptureStore source;
  _Store(this.source);
  @override
  WorkspaceCaptureStore init() => source;
}

class FaultListing implements Directory {
  final Directory original;
  int lists = 0;
  final Directory first, second;
  FaultListing(this.original, this.first, this.second);
  @override
  String get path => original.path;
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    lists++;
    if (lists == 1) return;
    if (lists == 2) {
      yield first;
      throw const FileSystemException('injected directory read error');
    }
    if (await second.exists()) yield second;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('interrupted listing preserves actual counts and retry opens a new scan', () async {
    final root = await Directory.systemTemp.createTemp('capture-retry-');
    final first = Directory(p.join(root.path, const Uuid().v4()));
    final second = Directory(p.join(root.path, const Uuid().v4()));
    final wrapper = FaultListing(root, first, second);
    final store = WorkspaceCaptureStore(
      root,
      removeStage: (_, id) async {
        final directory = id == p.basename(first.path) ? first : second;
        await File(p.join(directory.path, 'source-0')).delete();
        await directory.delete();
        return jsonEncode(const CaptureCleanupReport(examined: 1, removedStages: 1, removedFiles: 1, unlinkedBytes: 5).toJson());
      },
    );
    final container = RefenaContainer(overrides: [workspaceCaptureStoreProvider.overrideWithNotifier((_) => _Store(store))]);
    try {
      final service = container.notifier(workspaceCaptureStoreProvider);
      final parentZone = Zone.current;
      await IOOverrides.runZoned(
        () => service.ready(),
        createDirectory: (_) => wrapper,
        fseGetType: (path, follow) => parentZone.run(() => FileSystemEntity.type(path, followLinks: follow)),
      );
      for (final directory in [first, second]) {
        await directory.create();
        await File(p.join(directory.path, 'source-0')).writeAsString('hello');
      }
      await expectLater(service.clean(), throwsA(isA<CaptureCleanupInterrupted>()));
      final interrupted = container.read(workspaceCaptureMaintenanceProvider);
      expect(interrupted.interrupted, true);
      expect(interrupted.busy, false);
      expect(interrupted.report!.unlinkedBytes, 5);
      expect(await second.exists(), true);
      await service.clean();
      final retry = container.read(workspaceCaptureMaintenanceProvider);
      expect(retry.interrupted, false);
      expect(retry.report!.removedStages, 1);
      expect(await second.exists(), false);
      expect(wrapper.lists, 3);
    } finally {
      container.disposeContainer();
      await store.close();
      await root.delete(recursive: true);
    }
  });

  test('capture ready and maintenance await the same first batch and publish it once', () async {
    final root = await Directory.systemTemp.createTemp('capture-init-race-');
    final id = const Uuid().v4();
    final stage = await Directory(p.join(root.path, id)).create();
    await File(p.join(stage.path, 'source-0')).writeAsString('hello');
    final reached = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final store = WorkspaceCaptureStore(
      root,
      removeStage: (root, id) async {
        calls++;
        reached.complete();
        await release.future;
        await File(p.join(stage.path, 'source-0')).delete();
        await stage.delete();
        return jsonEncode(const CaptureCleanupReport(examined: 1, removedStages: 1, removedFiles: 1, unlinkedBytes: 5).toJson());
      },
    );
    final container = RefenaContainer(overrides: [workspaceCaptureStoreProvider.overrideWithNotifier((_) => _Store(store))]);
    try {
      final service = container.notifier(workspaceCaptureStoreProvider);
      final preparing = service.ready();
      await reached.future;
      expect(store.initialized, false);
      var completed = false;
      final cleaning = service.clean().then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(completed, false);
      expect(calls, 1);
      release.complete();
      await preparing;
      await cleaning;
      expect(container.read(workspaceCaptureMaintenanceProvider).report!.unlinkedBytes, 5);
      expect(container.read(workspaceCaptureMaintenanceProvider).batches, 1);
      await service.clean();
      expect(container.read(workspaceCaptureMaintenanceProvider).report!.unlinkedBytes, 0);
    } finally {
      container.disposeContainer();
      await store.close();
      await root.delete(recursive: true);
    }
  });
  test('first startup deletion is included in visible totals, not replaced by an empty scan', () async {
    final root = await Directory.systemTemp.createTemp('export-maintenance-');
    final id = const Uuid().v4();
    final stage = await Directory(p.join(root.path, id)).create();
    await File(p.join(stage.path, 'owner.json')).writeAsString(jsonEncode({'format': 'legnasend.workspace-capture.v1', 'id': id, 'count': 1}));
    await File(p.join(stage.path, 'source-0')).writeAsString('hello');
    final store = WorkspaceCaptureStore.leaseProbe(root);
    final container = RefenaContainer(overrides: [workspaceCaptureStoreProvider.overrideWithNotifier((_) => _Store(store))]);
    try {
      await container.notifier(workspaceCaptureStoreProvider).initialize();
      final report = container.read(workspaceCaptureMaintenanceProvider);
      expect(report.report!.removedStages, 1);
      expect(report.report!.removedFiles, 1);
      expect(report.report!.unlinkedBytes, 5);
      expect(report.batches, 1);
      expect(report.busy, false);
      expect(await stage.exists(), false);
      await container.notifier(workspaceCaptureStoreProvider).clean();
      expect(container.read(workspaceCaptureMaintenanceProvider).report!.unlinkedBytes, 0);
    } finally {
      container.disposeContainer();
      await store.close();
      await root.delete(recursive: true);
    }
  });
}
