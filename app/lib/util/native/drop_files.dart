import 'dart:io';

import 'package:image_picker/image_picker.dart' show XFile;
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:path/path.dart' as p;

/// Snapshot a single drop without altering the shared selection. Failed
/// conversion rejects the whole drop instead of silently sending a partial set.
Future<List<CrossFile>> collectDroppedFiles(
  Iterable<String> paths, {
  Future<CrossFile> Function(XFile)? convertFile,
  Future<List<CrossFile>> Function(String)? convertDirectory,
  void Function(int count)? onEmptyDirectories,
}) async {
  final files = <String, CrossFile>{};
  final emptyDirectories = <String>{};
  for (final path in paths) {
    final type = await FileSystemEntity.type(path, followLinks: false);
    final List<CrossFile> converted;
    if (type == FileSystemEntityType.directory) {
      converted = convertDirectory != null
          ? await convertDirectory(path)
          : await readDirectoryFiles(
              path,
              onEmptyDirectoryPaths: (paths) => emptyDirectories.addAll(paths.map((path) => p.normalize(p.absolute(path)))),
            );
    } else if (type == FileSystemEntityType.file) {
      converted = [await (convertFile ?? CrossFileConverters.convertXFile)(XFile(path))];
    } else {
      throw FileSystemException('Dropped item is missing or is not a regular file/directory', path);
    }
    for (final file in converted) {
      files.putIfAbsent(p.normalize(p.absolute(file.path ?? path)), () => file);
    }
  }
  onEmptyDirectories?.call(emptyDirectories.length);
  return List.unmodifiable(files.values);
}
