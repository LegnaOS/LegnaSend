import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'workspace_fixtures.dart';

void main() {
  test('batch opens selected entries independently and preserves access policies with partial failure', () async {
    final store = MemoryWorkspaceStore([
      workspace(1, visible: false).copyWith(allowUpload: true, passwordHash: fixturePasswordHash),
      workspace(2),
      workspace(3),
    ]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: (source) async => source.locator.endsWith('/2')
          ? const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.missing)
          : WorkspaceProbeResult.valid(source.locator),
    );
    await catalog.initialize();
    final results = await catalog.setEnabledBatch(catalog.state.entries.take(2).toList(), true);
    expect(results.map((r) => r.outcome), [WorkspaceBatchOutcome.applied, WorkspaceBatchOutcome.invalid]);
    final first = catalog.state.entries.first;
    expect(first.enabled, true);
    expect(first.visible, false);
    expect(first.allowUpload, true);
    expect(first.passwordHash, fixturePasswordHash);
    expect(catalog.state.entries[1].enabled, false);
    expect(catalog.state.entries[2].enabled, false);
    final opened = first;
    await catalog.setEnabledBatch([opened], true);
    expect(catalog.state.entries.first.generation, opened.generation, reason: 'Opening an already open share must not revoke its transfers');
    await catalog.enable(workspaceId(3));
    await catalog.setEnabledBatch([opened], false);
    expect(catalog.state.entries.first.enabled, false);
    expect(catalog.state.entries.last.enabled, true);
  });
  test('stale confirmation skips changed entry and continues unchanged siblings', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1), workspace(2)]), probe: validProbe);
    await catalog.initialize();
    final selection = catalog.state.entries;
    await catalog.update(workspaceId(1), visible: false);
    final result = await catalog.setEnabledBatch(selection, true);
    expect(result.map((r) => r.outcome), [WorkspaceBatchOutcome.changed, WorkspaceBatchOutcome.applied]);
    expect(catalog.state.entries.first.enabled, false);
    expect(catalog.state.entries.last.enabled, true);
  });
}
