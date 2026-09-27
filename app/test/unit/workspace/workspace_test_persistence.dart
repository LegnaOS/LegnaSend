import '../../mocks.mocks.dart';

/// Minimal real content persistence for publication tests, without native prefs.
class MemoryWorkspacePersistence extends MockPersistenceService {
  String? _content;
  @override
  String? getWorkspaceContent() => _content;
  @override
  Future<void> setWorkspaceContent(String value) async => _content = value;
}
