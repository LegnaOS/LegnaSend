import 'package:dart_mappable/dart_mappable.dart';

part 'directory_workspace.mapper.dart';

/// A locator is private configuration, never a public file-list DTO.
@MappableEnum()
enum WorkspaceSourceKind { directory, androidTree, appleBookmark }

@MappableClass()
class WorkspaceSource with WorkspaceSourceMappable {
  final WorkspaceSourceKind kind;
  final String locator;

  /// Opaque reference to a platform grant; not a password or API credential.
  final String? grantId;

  const WorkspaceSource({required this.kind, required this.locator, this.grantId});
}

@MappableEnum()
enum WorkspaceInvalidReason { missing, notDirectory, permissionDenied, grantUnavailable, ioError, timeout }

/// Persisted user intent. Enabled does NOT mean a route is already published.
/// Runtime directory checks and server publication are separate gates.
@MappableClass()
class DirectoryWorkspace with DirectoryWorkspaceMappable {
  final String id;
  final String name;
  final String slug;
  final WorkspaceSource source;
  final bool enabled;
  final bool visible;

  /// Explicit browser write permission; existing and newly created workspaces are read-only.
  final bool allowUpload;

  /// One-way salted verifier; never a plaintext password or a browser token.
  final String? passwordHash;

  /// Changes on every configuration/lifecycle transition and startup validation.
  /// A future server adapter must bind callbacks and grants to (id, generation).
  /// This is not the directory content version used by paginated file listings.
  final int generation;
  final WorkspaceInvalidReason? invalidReason;

  const DirectoryWorkspace({
    required this.id,
    required this.name,
    required this.slug,
    required this.source,
    required this.enabled,
    required this.visible,
    required this.generation,
    this.invalidReason,
    this.passwordHash,
    this.allowUpload = false,
  });

  @override
  String toString() => 'DirectoryWorkspace(id: $id, generation: $generation, enabled: $enabled, protected: ${passwordHash != null})';

  static const fromJson = DirectoryWorkspaceMapper.fromJson;
}
