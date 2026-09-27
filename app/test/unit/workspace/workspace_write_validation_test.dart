import 'dart:async';

import 'package:flutter/services.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:test/test.dart';

import 'workspace_fixtures.dart';

DirectoryWorkspace tree(int index, {bool enabled = true, bool upload = true}) => workspace(index, enabled: enabled).copyWith(
  source: WorkspaceSource(kind: WorkspaceSourceKind.androidTree, locator: 'content://fixture.provider/tree/root-$index'),
  allowUpload: upload,
);
Future<WorkspaceProbeResult> readable(WorkspaceSource source) async =>
    source.kind == WorkspaceSourceKind.androidTree ? WorkspaceProbeResult.documents(source.locator) : WorkspaceProbeResult.valid(source.locator);

void main() {
  test('startup disables only an upload tree with lost write authority before publication', () async {
    final bad = tree(1);
    final healthy = workspace(2, enabled: true);
    final readonly = tree(3, upload: false);
    final closed = tree(4, enabled: false);
    final calls = <String>[];
    final store = MemoryWorkspaceStore([bad, healthy, readonly, closed]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (source) async {
        calls.add(source.locator);
        throw PlatformException(code: 'permission');
      },
    );
    await catalog.initialize();
    final invalid = catalog.state.entries.first;
    expect(invalid.enabled, isFalse);
    expect(invalid.allowUpload, isTrue, reason: 'Keep requested policy; never silently downgrade to read-only');
    expect(invalid.invalidReason, WorkspaceInvalidReason.permissionDenied);
    expect(catalog.state.verifiedLocators.containsKey(bad.id), isFalse);
    expect(catalog.state.publishable.map((entry) => entry.id), [healthy.id, readonly.id]);
    expect(catalog.state.entries.last, closed);
    expect(calls, [bad.source.locator]);
    expect(WorkspaceCatalogCodec.decode(store.raw).first, invalid);
  });

  test('recovered write grant stays closed across restart and validate until explicit enable', () async {
    final original = tree(1);
    final store = MemoryWorkspaceStore([original]);
    final first = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (_) async => throw PlatformException(code: 'permission'),
    );
    await first.initialize();
    var calls = 0;
    final recovered = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (_) async {
        calls++;
      },
    );
    await recovered.initialize();
    expect(calls, 0);
    expect(recovered.state.publishable, isEmpty);
    final checked = await recovered.validate(original.id);
    expect(checked.enabled, isFalse);
    expect(checked.invalidReason, isNull);
    expect(checked.allowUpload, isTrue);
    expect(recovered.state.publishable, isEmpty);
    expect((await recovered.enable(original.id)).enabled, isTrue);
    expect(calls, 2);
  });

  for (final action in ['enable', 'validate', 'batch', 'api-enable', 'api-validate']) {
    test('$action rechecks complete entry capabilities and isolates a newly revoked tree', () async {
      var writable = true;
      final target = tree(1), healthy = tree(2, upload: false);
      final catalog = WorkspaceCatalog(
        store: MemoryWorkspaceStore([target, healthy]),
        probe: readable,
        writeProbe: (_) async {
          if (!writable) throw PlatformException(code: 'permission');
        },
      );
      await catalog.initialize();
      writable = false;
      final old = catalog.state.entries.first;
      switch (action) {
        case 'enable':
          await catalog.enable(old.id);
        case 'validate':
          await catalog.validate(old.id);
        case 'batch':
          final results = await catalog.setEnabledBatch([old], true);
          expect(results.single.outcome, WorkspaceBatchOutcome.invalid);
        case 'api-enable':
          await catalog.manage(id: old.id, generation: old.generation, action: WorkspaceManagementAction.enable, claim: () async => true);
        case 'api-validate':
          await catalog.manage(id: old.id, generation: old.generation, action: WorkspaceManagementAction.validate, claim: () async => true);
      }
      expect(catalog.state.entries.first.enabled, isFalse);
      expect(catalog.state.entries.first.allowUpload, isTrue);
      expect(catalog.state.entries.first.invalidReason, WorkspaceInvalidReason.permissionDenied);
      expect(catalog.state.publishable.map((entry) => entry.id), [healthy.id]);
    });
  }

  test('batch enable rechecks healthy entries without generation or disk churn', () async {
    var calls = 0;
    final store = MemoryWorkspaceStore([tree(1)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (_) async {
        calls++;
      },
    );
    await catalog.initialize();
    final old = catalog.state.entries.single;
    final writes = store.writes;
    await catalog.setEnabledBatch([old], true);
    expect(calls, 2);
    expect(catalog.state.entries.single, old);
    expect(store.writes, writes);
  });

  test('write timeout disables persistently and ignores a late successful response', () async {
    final pending = Completer<void>();
    final store = MemoryWorkspaceStore([tree(1), tree(2, upload: false)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (_) => pending.future,
      probeTimeout: const Duration(milliseconds: 10),
    );
    await catalog.initialize();
    final state = catalog.state;
    expect(state.entries.first.invalidReason, WorkspaceInvalidReason.timeout);
    expect(state.publishable.single.id, workspaceId(2));
    pending.complete();
    await Future<void>.delayed(Duration.zero);
    expect(identical(catalog.state, state), isTrue);
    expect(WorkspaceCatalogCodec.decode(store.raw).first.enabled, isFalse);
  });

  test('queued close cannot be undone by an in-flight write capability check', () async {
    final pending = Completer<void>(), started = Completer<void>();
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([tree(1, enabled: false)]),
      probe: readable,
      writeProbe: (_) {
        started.complete();
        return pending.future;
      },
    );
    await catalog.initialize();
    final opening = catalog.enable(workspaceId(1));
    await started.future;
    final closing = catalog.disable(workspaceId(1));
    pending.complete();
    await opening;
    await closing;
    expect(catalog.state.entries.single.enabled, isFalse);
    expect(catalog.state.publishable, isEmpty);
  });

  test('persistence failure preserves disk but cannot republish known-invalid runtime authority', () async {
    var writable = true;
    final store = MemoryWorkspaceStore([tree(1), tree(2, upload: false)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: readable,
      writeProbe: (_) async {
        if (!writable) throw PlatformException(code: 'permission');
      },
    );
    await catalog.initialize();
    final disk = store.raw;
    writable = false;
    store.failWrite = true;
    await expectLater(catalog.validate(workspaceId(1)), throwsA(isA<WorkspaceCatalogException>()));
    expect(store.raw, disk);
    expect(catalog.state.verifiedLocators.containsKey(workspaceId(1)), isFalse);
    expect(catalog.state.publishable.single.id, workspaceId(2));
    store.failWrite = false;
    await catalog.validate(workspaceId(1));
    expect(WorkspaceCatalogCodec.decode(store.raw).first.enabled, isFalse);
  });

  test('write provider errors are typed and do not affect read-only trees', () async {
    for (final error in [PlatformException(code: 'provider_error'), StateError('unavailable')]) {
      final result = await probeWorkspaceEntry(tree(1), readProbe: readable, writeProbe: (_) async => throw error);
      expect(result.invalidReason, WorkspaceInvalidReason.ioError);
      expect(result.verifiedLocator, isNull);
    }
    final read = await probeWorkspaceEntry(
      tree(2, upload: false),
      readProbe: readable,
      writeProbe: (_) async => throw StateError('Read-only must not probe write authority'),
    );
    expect(read.isValid, isTrue);
  });
}
