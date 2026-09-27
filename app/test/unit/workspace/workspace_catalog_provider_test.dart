import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';
import 'workspace_fixtures.dart';

void main() {
  test('provider mirrors persisted changes without any server/network provider', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(_Persistence(store))]);
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(workspaceCatalogProvider);
    await notifier.catalog.initialize();
    expect(container.read(workspaceCatalogProvider).entries, [workspace(1)]);
    await notifier.catalog.update(workspaceId(1), name: 'Updated');
    expect(container.read(workspaceCatalogProvider).entries.single.name, 'Updated');
    expect(WorkspaceCatalogCodec.decode(store.raw).single.name, 'Updated');
    await notifier.catalog.destroy(workspaceId(1));
    expect(container.read(workspaceCatalogProvider).entries, isEmpty);
  });

  test('disposing the provider closes its catalog', () async {
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(_Persistence(MemoryWorkspaceStore()))]);
    final catalog = container.notifier(workspaceCatalogProvider).catalog;
    await catalog.initialize();
    container.disposeContainer();
    await expectLater(catalog.destroy(workspaceId(1)), throwsStateError);
  });
}

class _Persistence extends MockPersistenceService {
  final MemoryWorkspaceStore store;
  _Persistence(this.store);

  @override
  String? getWorkspaceCatalog() => store.raw;

  @override
  Future<void> setWorkspaceCatalog(String? value) => store.write(value!);
}
