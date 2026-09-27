import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:refena_flutter/refena_flutter.dart';

final workspaceCatalogProvider = NotifierProvider<WorkspaceCatalogNotifier, WorkspaceCatalogState>((ref) => WorkspaceCatalogNotifier());

/// Configuration only: no networking or isolate side channel. The server bridge
/// will consume validated candidates through normal parent-isolate actions.
class WorkspaceCatalogNotifier extends Notifier<WorkspaceCatalogState> {
  late final WorkspaceCatalog catalog;

  @override
  WorkspaceCatalogState init() {
    catalog = WorkspaceCatalog(
      store: _PreferencesWorkspaceStore(ref.read(persistenceProvider)),
      onChanged: (value) => state = value,
    );
    return const WorkspaceCatalogState();
  }

  @override
  void dispose() {
    catalog.dispose();
    super.dispose();
  }
}

class _PreferencesWorkspaceStore implements WorkspaceCatalogStore {
  final PersistenceService persistence;

  _PreferencesWorkspaceStore(this.persistence);

  @override
  Future<String?> read() async => persistence.getWorkspaceCatalog();

  @override
  Future<void> write(String value) => persistence.setWorkspaceCatalog(value);
}
