import 'dart:convert';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/approved_workspace_source.dart';

/// A separate versioned envelope avoids treating unknown/corrupt settings as an
/// empty catalog and overwriting them at startup. These limits bound local input.
class WorkspaceCatalogCodec {
  static const version = 4;
  static const maxEntries = 256;
  static const maxEncodedLength = 2 * 1024 * 1024;
  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
  static final _slug = RegExp(r'^[a-z][a-z0-9-]{0,47}$');
  static final _controls = RegExp(r'[\x00-\x1f\x7f]');
  static const reservedSlugs = {'api', 'assets', 'i18n', 'upload', 'download', 'share', 'internal', 'favicon', 'robots', 'workspace'};

  static void validatePasswordHash(String? value) {
    if (value == null) return;
    final fields = value.split(r'$');
    try {
      if (fields.length != 4 || fields[0] != 'pbkdf2-sha256' || fields[1] != '600000') throw const FormatException();
      for (final (part, length) in [(fields[2], 16), (fields[3], 32)]) {
        final bytes = base64Url.decode(base64Url.normalize(part));
        if (bytes.length != length || base64Url.encode(bytes).replaceAll('=', '') != part) throw const FormatException();
      }
    } catch (_) {
      throw const FormatException('Invalid workspace password verifier');
    }
  }

  static String normalizeSlug(String input) => input.trim().toLowerCase();

  static void validate(DirectoryWorkspace entry) {
    validatePasswordHash(entry.passwordHash);
    if (_uuid.stringMatch(entry.id) != entry.id) throw const FormatException('Invalid workspace ID');
    if (entry.name.trim() != entry.name || entry.name.isEmpty || entry.name.length > 120 || _controls.hasMatch(entry.name)) {
      throw const FormatException('Invalid workspace name');
    }
    if (_slug.stringMatch(entry.slug) != entry.slug || reservedSlugs.contains(entry.slug) || entry.slug.endsWith('-')) {
      throw const FormatException('Invalid or reserved workspace route');
    }
    if (entry.source.locator.isEmpty || entry.source.locator.length > 32768 || _controls.hasMatch(entry.source.locator)) {
      throw const FormatException('Invalid workspace source');
    }
    final grant = entry.source.grantId;
    if (grant != null && (grant.isEmpty || grant.length > 4096 || _controls.hasMatch(grant))) {
      throw const FormatException('Invalid workspace grant reference');
    }
    if (entry.source.kind == WorkspaceSourceKind.appleBookmark && grant == null) {
      throw const FormatException('Missing workspace grant reference');
    }
    if (entry.source.kind == WorkspaceSourceKind.androidTree) {
      final uri = Uri.tryParse(entry.source.locator);
      if (uri == null || uri.scheme != 'content' || uri.host.isEmpty || !uri.pathSegments.contains('tree') || uri.hasQuery || uri.hasFragment) {
        throw const FormatException('Invalid document tree URI');
      }
    }
    if (entry.generation < 1 || entry.generation >= 0x1fffffffffffff) throw const FormatException('Invalid workspace generation');
    if (entry.enabled && entry.invalidReason != null) throw const FormatException('Invalid workspace enable state');
  }

  static void validateAll(List<DirectoryWorkspace> entries) {
    if (entries.length > maxEntries) throw const FormatException('Workspace catalog limit exceeded');
    final ids = <String>{};
    final slugs = <String>{};
    for (final entry in entries) {
      validate(entry);
      if (!ids.add(entry.id) || !slugs.add(entry.slug)) throw const FormatException('Duplicate workspace identity or route');
    }
  }

  static String encode(List<DirectoryWorkspace> entries, {List<ApprovedWorkspaceSource> approvedSources = const []}) {
    validateAll(entries);
    validateApprovals(approvedSources);
    final result = jsonEncode({
      'version': version,
      'workspaces': entries.map((entry) => entry.toJson()).toList(),
      'approvedSources': approvedSources.map((source) => source.toJson()).toList(),
    });
    if (result.length > maxEncodedLength) throw const FormatException('Workspace catalog size exceeded');
    return result;
  }

  static List<DirectoryWorkspace> decode(String? raw) {
    if (raw == null) return const [];
    if (raw.length > maxEncodedLength) throw const FormatException('Workspace catalog size exceeded');
    final dynamic data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Malformed workspace catalog');
    }
    if (data is! Map<String, dynamic> ||
        data.keys.any((key) => !{'version', 'workspaces', 'approvedSources'}.contains(key)) ||
        data['version'] is! int ||
        ![1, 2, 3, version].contains(data['version']) ||
        data['workspaces'] is! List) {
      throw const FormatException('Unsupported workspace catalog');
    }
    final rows = data['workspaces'] as List;
    if (rows.length > maxEntries) throw const FormatException('Workspace catalog limit exceeded');
    final entries = <DirectoryWorkspace>[];
    for (final row in rows) {
      // The mapper can coerce primitives. Stored permission flags must instead
      // be exact JSON booleans, never strings/numbers with surprising defaults.
      if (row is! Map<String, dynamic> ||
          row.keys.any(
            (key) =>
                !{'id', 'name', 'slug', 'source', 'enabled', 'visible', 'generation', 'invalidReason', 'passwordHash', 'allowUpload'}.contains(key),
          ) ||
          row['id'] is! String ||
          row['name'] is! String ||
          (row['passwordHash'] != null && (row['passwordHash'] is! String || data['version'] == 1)) ||
          row['slug'] is! String ||
          row['enabled'] is! bool ||
          row['visible'] is! bool ||
          (row.containsKey('allowUpload') && row['allowUpload'] is! bool) ||
          (data['version'] < 3 && row['allowUpload'] == true) ||
          row['generation'] is! int ||
          row['source'] is! Map<String, dynamic>) {
        throw const FormatException('Malformed workspace configuration');
      }
      final source = row['source'] as Map<String, dynamic>;
      if (source.keys.any((key) => !{'kind', 'locator', 'grantId'}.contains(key)) ||
          source['kind'] is! String ||
          source['locator'] is! String ||
          (source['grantId'] != null && source['grantId'] is! String) ||
          (row['invalidReason'] != null && row['invalidReason'] is! String)) {
        throw const FormatException('Malformed workspace source');
      }
      try {
        entries.add(DirectoryWorkspace.fromJson(row));
      } catch (_) {
        // Do not include raw locators or future secrets in parse exceptions.
        throw const FormatException('Malformed workspace configuration');
      }
    }
    validateAll(entries);
    decodeApprovals(raw);
    return List.unmodifiable(entries);
  }

  static void validateApprovals(List<ApprovedWorkspaceSource> sources) {
    if (sources.length > 64) throw const FormatException('Approved source limit exceeded');
    final ids = <String>{};
    for (final source in sources) {
      if (!ids.add(source.id)) throw const FormatException('Duplicate approved source');
      validate(
        DirectoryWorkspace(
          id: source.id,
          name: source.name,
          slug: 'approved-source',
          source: source.source,
          enabled: false,
          visible: false,
          generation: 1,
        ),
      );
    }
  }

  static List<ApprovedWorkspaceSource> decodeApprovals(String? raw) {
    if (raw == null) return const [];
    if (raw.length > maxEncodedLength) throw const FormatException('Workspace catalog size exceeded');
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) throw const FormatException('Malformed approved sources');
    final rows = data['approvedSources'];
    if (data['version'] != version) {
      if (rows != null) throw const FormatException('Unexpected approved sources');
      return const [];
    }
    if (rows is! List || rows.length > 64) throw const FormatException('Malformed approved sources');
    final sources = <ApprovedWorkspaceSource>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row.length != 3 ||
          row['id'] is! String ||
          row['name'] is! String ||
          row['source'] is! Map<String, dynamic>) {
        throw const FormatException('Malformed approved source');
      }
      final source = row['source'] as Map<String, dynamic>;
      if (source.keys.any((key) => !{'kind', 'locator', 'grantId'}.contains(key)) ||
          source['kind'] is! String ||
          source['locator'] is! String ||
          source['grantId'] != null && source['grantId'] is! String) {
        throw const FormatException('Malformed approved source');
      }
      try {
        sources.add(ApprovedWorkspaceSource(id: row['id'] as String, name: row['name'] as String, source: WorkspaceSourceMapper.fromJson(source)));
      } catch (_) {
        throw const FormatException('Malformed approved source');
      }
    }
    validateApprovals(sources);
    return List.unmodifiable(sources);
  }
}
