import 'package:localsend_app/model/persistence/directory_workspace.dart';

/// Local-only durable authority. Remote callers receive id/name/kind, never the locator.
class ApprovedWorkspaceSource {
  final String id;
  final String name;
  final WorkspaceSource source;
  const ApprovedWorkspaceSource({required this.id, required this.name, required this.source});
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'source': source.toJson()};
  Map<String, Object?> descriptor() => {'id': id, 'name': name, 'kind': source.kind.name};
}
