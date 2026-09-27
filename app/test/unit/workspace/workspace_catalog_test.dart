import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:test/test.dart';

import 'workspace_fixtures.dart';

void main() {
  test('missing catalog initializes once and never writes an empty replacement', () async {
    final store = MemoryWorkspaceStore();
    final catalog = WorkspaceCatalog(store: store);
    await Future.wait([catalog.initialize(), catalog.initialize()]);
    expect(store.reads, 1);
    expect(store.writes, 0);
    expect(catalog.state.initialized, true);
    expect(catalog.state.entries, isEmpty);
  });

  test('create is closed, normalizes display/route and persists across instances', () async {
    final store = MemoryWorkspaceStore();
    final catalog = WorkspaceCatalog(store: store, newId: () => workspaceId(1), probe: (_) => throw StateError('must not probe closed items'));
    final entry = await catalog.create(name: ' 私人资料 ', slug: ' WorkSPACE1 ', source: workspace(1).source, visible: false);
    expect(entry.name, '私人资料');
    expect(entry.slug, 'workspace1');
    expect(entry.enabled, false);
    expect(entry.visible, false);
    expect(catalog.state.publishable, isEmpty);
    final reopened = WorkspaceCatalog(store: store, probe: (_) => throw StateError('must remain closed'));
    await reopened.initialize();
    expect(reopened.state.entries, [entry]);
    expect(reopened.state.publishable, isEmpty);
  });

  test('upload permission persists independently and invalidates only its workspace generation', () async {
    final store = MemoryWorkspaceStore([workspace(1, enabled: true), workspace(2, enabled: true)]);
    final catalog = WorkspaceCatalog(store: store, probe: validProbe);
    await catalog.initialize();
    final old = catalog.state.entries.first;
    final other = catalog.state.entries.last;
    final writable = await catalog.setAllowUpload(old.id, true);
    expect(writable.allowUpload, true);
    expect(writable.generation, old.generation + 1);
    expect(catalog.state.verifiedLocators[writable.id], '/workspace/1');
    expect(catalog.state.entries.last, other);
    expect(WorkspaceCatalogCodec.decode(store.raw).first.allowUpload, true);
    final writes = store.writes;
    expect(await catalog.setAllowUpload(old.id, true), writable);
    expect(store.writes, writes);
    final disabled = await catalog.setAllowUpload(old.id, false);
    expect(disabled.allowUpload, false);
    expect(disabled.generation, writable.generation + 1);
    expect(disabled.enabled, true);
    expect(catalog.state.entries.last, other);
  });

  test('display rename and visibility keep route and ID, stale generation is rejected', () async {
    final store = MemoryWorkspaceStore([workspace(1, enabled: true), workspace(2, enabled: true)]);
    final catalog = WorkspaceCatalog(store: store, probe: validProbe);
    await catalog.initialize();
    final before = catalog.state.entries.first;
    final unrelated = catalog.state.entries.last;
    expect(catalog.state.matches(before.id, before.generation), true);
    final after = await catalog.update(before.id, name: 'Renamed', visible: false);
    expect(after.slug, before.slug);
    expect(after.id, before.id);
    expect(after.visible, false);
    expect(catalog.state.matches(before.id, before.generation), false);
    expect(catalog.state.matches(after.id, after.generation), true);
    expect(catalog.state.entries.last, unrelated);
  });

  test('root/route changes require a closed workspace', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1, enabled: true)]), probe: validProbe);
    await catalog.initialize();
    await expectLater(catalog.update(workspaceId(1), slug: 'new-route'), throwsStateError);
    await expectLater(catalog.update(workspaceId(1), source: workspace(2).source), throwsStateError);
    await catalog.disable(workspaceId(1));
    final updated = await catalog.update(workspaceId(1), slug: 'new-route', source: workspace(2).source);
    expect(updated.slug, 'new-route');
    expect(updated.source, workspace(2).source);
    expect(catalog.state.publishable, isEmpty);
  });

  test('duplicate normalized route fails without overwriting an existing record', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store, newId: () => workspaceId(2));
    await catalog.initialize();
    final original = store.raw;
    await expectLater(catalog.create(name: 'Another', slug: ' WORKSPACE1 ', source: workspace(2).source), throwsFormatException);
    expect(store.raw, original);
    expect(catalog.state.entries, [workspace(1)]);
  });

  test('startup disables invalid enabled sources, retains reason, and skips closed ones', () async {
    final probed = <String>[];
    final store = MemoryWorkspaceStore([workspace(1, enabled: true), workspace(2, enabled: true), workspace(3)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: (source) async {
        probed.add(source.locator);
        return source.locator.endsWith('/1')
            ? WorkspaceProbeResult.valid(source.locator)
            : const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.missing);
      },
    );
    await catalog.initialize();
    expect(probed, ['/workspace/1', '/workspace/2']);
    expect(catalog.state.publishable.map((entry) => entry.id), [workspaceId(1)]);
    final disabled = catalog.state.entries[1];
    expect(disabled.enabled, false);
    expect(disabled.invalidReason, WorkspaceInvalidReason.missing);
    expect(disabled.generation, 2);
    expect(catalog.state.entries.last, workspace(3));
    expect(WorkspaceCatalogCodec.decode(store.raw)[1], disabled);
    final reopened = WorkspaceCatalog(store: store, probe: validProbe);
    await reopened.initialize();
    expect(reopened.state.entries[1], disabled); // fixed disk does not auto-reenable
  });

  test('validation after repair does not reopen; explicit enable is required', () async {
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([workspace(1, invalidReason: WorkspaceInvalidReason.missing)]),
      probe: validProbe,
    );
    await catalog.initialize();
    final repaired = await catalog.validate(workspaceId(1));
    expect(repaired.enabled, false);
    expect(repaired.invalidReason, isNull);
    expect(catalog.state.publishable, isEmpty);
    final enabled = await catalog.enable(workspaceId(1));
    expect(enabled.enabled, true);
    expect(catalog.state.matches(enabled.id, enabled.generation), true);
  });

  test('invalid explicit enable is saved as disabled with a typed reason', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store, probe: (_) async => const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.permissionDenied));
    final entry = await catalog.enable(workspaceId(1));
    expect(entry.enabled, false);
    expect(entry.invalidReason, WorkspaceInvalidReason.permissionDenied);
    expect(catalog.state.publishable, isEmpty);
    expect(WorkspaceCatalogCodec.decode(store.raw).single, entry);
  });

  test('new generation is not publishable until its storage write succeeds', () async {
    final store = _GatedStore([workspace(1, enabled: true)]);
    final catalog = WorkspaceCatalog(store: store, probe: validProbe);
    final loading = catalog.initialize();
    await store.writing.future;
    expect(catalog.state.checking, true);
    expect(catalog.state.publishable, isEmpty);
    store.release.complete();
    await loading;
    expect(catalog.state.publishable, hasLength(1));
  });

  test('startup write failure publishes nothing, preserves disk and can recover', () async {
    final store = MemoryWorkspaceStore([workspace(1, enabled: true)])..failWrite = true;
    final original = store.raw;
    final catalog = WorkspaceCatalog(store: store, probe: validProbe);
    await expectLater(catalog.initialize(), throwsA(isA<WorkspaceCatalogException>()));
    expect(catalog.state.failure, WorkspaceCatalogFailure.write);
    expect(catalog.state.publishable, isEmpty);
    expect(store.raw, original);
    store.failWrite = false;
    await catalog.reload();
    expect(catalog.state.publishable, hasLength(1));
  });

  test('malformed or future catalog stays intact and all mutations are blocked', () async {
    final store = MemoryWorkspaceStore()..raw = '{"version":999,"workspaces":[]}';
    final catalog = WorkspaceCatalog(store: store);
    await expectLater(catalog.initialize(), throwsA(isA<WorkspaceCatalogException>()));
    expect(catalog.state.failure, WorkspaceCatalogFailure.malformed);
    await expectLater(catalog.destroy(workspaceId(1)), throwsA(isA<WorkspaceCatalogException>()));
    expect(store.writes, 0);
    expect(store.raw, contains('999'));
    store.raw = WorkspaceCatalogCodec.encode([workspace(1)]);
    await catalog.reload();
    await catalog.destroy(workspaceId(1));
    expect(catalog.state.entries, isEmpty);
  });

  test('read failure does not leak source detail or write an empty catalog', () async {
    final store = MemoryWorkspaceStore()..failRead = true;
    final catalog = WorkspaceCatalog(store: store);
    await expectLater(
      catalog.initialize(),
      throwsA(predicate((Object e) => e is WorkspaceCatalogException && !e.toString().contains('private-path'))),
    );
    expect(catalog.state.failure, WorkspaceCatalogFailure.read);
    expect(store.writes, 0);
  });

  test('failed mutation keeps confirmed state and queue recovers on next operation', () async {
    final store = MemoryWorkspaceStore([workspace(1), workspace(2)]);
    final catalog = WorkspaceCatalog(store: store, probe: validProbe);
    await catalog.initialize();
    store.failWrite = true;
    await expectLater(catalog.destroy(workspaceId(1)), throwsA(isA<WorkspaceCatalogException>()));
    expect(catalog.state.entries, hasLength(2));
    store.failWrite = false;
    await catalog.destroy(workspaceId(1));
    expect(catalog.state.entries, [workspace(2)]);
  });

  test('concurrent mutations do not lose each other and old snapshots stay immutable', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1), workspace(2)]));
    await catalog.initialize();
    final oldState = catalog.state;
    await Future.wait([catalog.update(workspaceId(1), name: 'A'), catalog.update(workspaceId(2), name: 'B')]);
    expect(catalog.state.entries.map((entry) => entry.name), ['A', 'B']);
    expect(oldState.entries.map((entry) => entry.name), ['工作区 1', '工作区 2']);
    expect(() => catalog.state.entries.clear(), throwsUnsupportedError);
    expect(() => catalog.state.verifiedLocators.clear(), throwsUnsupportedError);
  });

  test('slow enable followed by destroy cannot resurrect a workspace', () async {
    final probeStarted = Completer<void>();
    final result = Completer<WorkspaceProbeResult>();
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([workspace(1), workspace(2)]),
      probe: (_) {
        probeStarted.complete();
        return result.future;
      },
    );
    await catalog.initialize();
    final enabling = catalog.enable(workspaceId(1));
    await probeStarted.future;
    final destroying = catalog.destroy(workspaceId(1));
    result.complete(const WorkspaceProbeResult.valid('/canonical'));
    final enabled = await enabling;
    await destroying;
    expect(catalog.state.entries, [workspace(2)]);
    expect(catalog.state.matches(enabled.id, enabled.generation), false);
    await expectLater(catalog.enable(workspaceId(1)), throwsStateError);
  });

  test('timeouts disable and late probe completion never changes state', () async {
    final result = Completer<WorkspaceProbeResult>();
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([workspace(1, enabled: true)]),
      probeTimeout: const Duration(milliseconds: 10),
      probe: (_) => result.future,
    );
    await catalog.initialize();
    expect(catalog.state.entries.single.invalidReason, WorkspaceInvalidReason.timeout);
    final state = catalog.state;
    result.complete(const WorkspaceProbeResult.valid('/late'));
    await Future<void>.delayed(Duration.zero);
    expect(identical(catalog.state, state), true);
  });

  test('startup probes at most four directories concurrently', () async {
    var active = 0;
    var highWater = 0;
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore(List.generate(13, (i) => workspace(i, enabled: true))),
      probe: (source) async {
        active++;
        if (active > highWater) highWater = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        return WorkspaceProbeResult.valid(source.locator);
      },
    );
    await catalog.initialize();
    expect(highWater, 4);
    expect(catalog.state.publishable, hasLength(13));
  });

  test('close and destroy preserve source files and unrelated configurations', () async {
    final root = await Directory.systemTemp.createTemp('legnasend-workspace-lifecycle-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File('${root.path}/source.txt').writeAsString('original bytes');
    final source = WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: root.path);
    final entry = workspace(1, enabled: true).copyWith(source: source);
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([entry, workspace(2)]));
    await catalog.initialize();
    expect(catalog.state.publishable, hasLength(1));
    await catalog.disable(entry.id);
    expect(catalog.state.publishable, isEmpty);
    await catalog.destroy(entry.id);
    await catalog.destroy(entry.id); // idempotent
    expect(catalog.state.entries, [workspace(2)]);
    expect(await file.readAsString(), 'original bytes');
  });

  test('disposed catalog cannot commit a late directory result', () async {
    final started = Completer<void>();
    final result = Completer<WorkspaceProbeResult>();
    final store = MemoryWorkspaceStore([workspace(1, enabled: true)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: (_) {
        started.complete();
        return result.future;
      },
    );
    final loading = catalog.initialize();
    await started.future;
    catalog.dispose();
    final expectation = expectLater(loading, throwsStateError);
    result.complete(const WorkspaceProbeResult.valid('/late'));
    await expectation;
    expect(store.writes, 0);
    expect(catalog.state.publishable, isEmpty);
  });
}

class _GatedStore extends MemoryWorkspaceStore {
  final writing = Completer<void>();
  final release = Completer<void>();
  _GatedStore(super.entries);

  @override
  Future<void> write(String value) async {
    writing.complete();
    await release.future;
    await super.write(value);
  }
}
