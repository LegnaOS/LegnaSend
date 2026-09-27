import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/native/drop_files.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:test/test.dart';

CrossFile fake(String path) => CrossFile(
  name: 'file.txt',
  fileType: FileType.text,
  size: 1,
  thumbnail: null,
  asset: null,
  path: path,
  bytes: null,
  lastModified: null,
  lastAccessed: null,
);
void main() {
  test('a drop snapshots only its own files and deduplicates repeated paths', () async {
    final dir = await Directory.systemTemp.createTemp('legnasend-drop-');
    try {
      final path = '${dir.path}/file.txt';
      await File(path).writeAsString('a');
      final files = await collectDroppedFiles(
        [dir.path, path, path],
        convertDirectory: (_) async => [fake(path)],
        convertFile: (f) async => fake(f.path),
      );
      expect(files.length, 1);
      expect(files.single.path, path);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('missing dropped file fails rather than silently sending a partial batch', () async {
    final dir = await Directory.systemTemp.createTemp('legnasend-drop-');
    try {
      final path = '${dir.path}/file.txt';
      await File(path).writeAsString('a');
      await expectLater(
        collectDroppedFiles([path, '${dir.path}/missing'], convertFile: (f) async => fake(f.path)),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
