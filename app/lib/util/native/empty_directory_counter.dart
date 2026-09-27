import 'dart:io';

import 'package:path/path.dart' as p;

/// Counts physically empty directories from the existing no-follow traversal.
/// Links and ignored files still occupy their parent; no extra reads or files.
class EmptyDirectoryCounter {
  final Set<String> _directories;
  final Set<String> _occupied = {};
  EmptyDirectoryCounter(String root) : _directories = {p.normalize(root)};

  void visit(FileSystemEntity entity) {
    _occupied.add(p.normalize(p.dirname(entity.path)));
    if (entity is Directory) _directories.add(p.normalize(entity.path));
  }

  Iterable<String> get emptyPaths => _directories.where((directory) => !_occupied.contains(directory));
  int get count => emptyPaths.length;
}
