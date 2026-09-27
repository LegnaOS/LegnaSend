import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';

/// Stable defaults never replace a name or route the user has edited.
String nextWorkspaceSlug(Iterable<String> existing, {String base = 'workspace'}) {
  final used = existing.toSet();
  if (base != 'workspace' && !used.contains(base) && !WorkspaceCatalogCodec.reservedSlugs.contains(base)) return base;
  for (var suffix = 1; ; suffix++) {
    final candidate = '$base$suffix';
    if (!used.contains(candidate) && !WorkspaceCatalogCodec.reservedSlugs.contains(candidate)) return candidate;
  }
}

String workspaceFolderName(String locator) {
  final uri = Uri.tryParse(locator);
  final path = uri?.scheme == 'content' && uri!.pathSegments.isNotEmpty ? uri.pathSegments.last.split(':').last : locator;
  final segments = path.replaceAll('\\', '/').split('/').where((part) => part.isNotEmpty).toList();
  final name = (segments.isEmpty ? '' : segments.last).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  // Avoid cutting a UTF-16 surrogate pair in folder names containing emoji.
  var result = '';
  for (final rune in name.runes) {
    final next = String.fromCharCode(rune);
    if (result.length + next.length > 120) break;
    result += next;
  }
  return result;
}
