import 'dart:convert';

/// Folder names come from provider traversal, never from decoding document IDs.
class AndroidFolderFile {
  final String name, relativePath, uri;
  final int size;
  final DateTime? lastModified;
  const AndroidFolderFile({required this.name, required this.relativePath, required this.uri, required this.size, this.lastModified});
}

class AndroidFolderSelection {
  final String directoryUri;
  final List<AndroidFolderFile> files;
  final int emptyDirectories;
  const AndroidFolderSelection._(this.directoryUri, this.files, this.emptyDirectories);

  static AndroidFolderSelection parse(Map<Object?, Object?> value) {
    Never invalid() => throw const FormatException('invalid folder selection');
    final directory = value['directoryUri'], entries = value['files'], empty = value['emptyDirectories'];
    final tree = directory is String ? Uri.tryParse(directory) : null;
    if (value['version'] != 1 ||
        tree == null ||
        tree.scheme != 'content' ||
        tree.authority.isEmpty ||
        directory is! String ||
        directory.length > 16384 ||
        entries is! List ||
        entries.length > 20000 ||
        empty is! int ||
        empty < 0 ||
        empty > 20001) {
      invalid();
    }
    final files = <AndroidFolderFile>[], paths = <String>{}, uris = <String>{};
    var budget = 0;
    for (final raw in entries) {
      if (raw is! Map) invalid();
      final name = raw['name'], path = raw['relativePath'], uri = raw['uri'], size = raw['size'], modified = raw['modifiedMillis'];
      if (name is! String ||
          path is! String ||
          uri is! String ||
          size is! int ||
          size < 0 ||
          size > 9007199254740991 ||
          (modified != null && (modified is! int || modified <= 0 || modified > 8640000000000000))) {
        invalid();
      }
      final parsed = Uri.tryParse(uri), components = path.split('/');
      if (parsed == null ||
          parsed.scheme != 'content' ||
          parsed.authority != tree.authority ||
          uri.length > 16384 ||
          components.length < 2 ||
          components.length > 65 ||
          components.last != name ||
          utf8.encode(path).length > 4096 ||
          components.any(
            (part) =>
                part.isEmpty || part == '.' || part == '..' || utf8.encode(part).length > 255 || part.runes.any((r) => r < 32 || r == 127 || r == 92),
          ) ||
          !paths.add(path) ||
          !uris.add(uri)) {
        invalid();
      }
      budget += 256 + 4 * (path.length + uri.length + name.length);
      if (budget > 16 * 1024 * 1024) invalid();
      files.add(
        AndroidFolderFile(
          name: name,
          relativePath: path,
          uri: uri,
          size: size,
          lastModified: modified == null ? null : DateTime.fromMillisecondsSinceEpoch(modified as int, isUtc: true),
        ),
      );
    }
    return AndroidFolderSelection._(directory, List.unmodifiable(files), empty);
  }
}
