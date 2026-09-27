import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/drop_files.dart';
import 'package:localsend_app/util/native/empty_directory_counter.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('legna-empty-folder-'));
  tearDown(() async => root.delete(recursive: true));

  test('the production reader reports one empty root and no placeholder file', () async {
    int? count;
    final files = await readDirectoryFiles(root.path, onEmptyDirectories: (value) => count = value);
    expect(files, isEmpty);
    expect(count, 1);
  });
  test('the production reader counts empty leaves rather than every ancestor', () async {
    await Directory(p.join(root.path, '中文', 'nested', 'empty')).create(recursive: true);
    await Directory(p.join(root.path, 'another')).create();
    int? count;
    final files = await readDirectoryFiles(root.path, onEmptyDirectories: (value) => count = value);
    expect(files, isEmpty);
    expect(count, 2);
    expect(await root.list(recursive: true).where((entry) => entry is File).length, 0);
  });
  test('zero-byte files and symlinks make a directory nonempty without following the link', () async {
    await Directory(p.join(root.path, 'files')).create();
    await File(p.join(root.path, 'files', 'zero')).create();
    await Directory(p.join(root.path, 'empty')).create();
    await Directory(p.join(root.path, 'linked')).create();
    if (!Platform.isWindows) await Link(p.join(root.path, 'linked', 'link')).create(root.path);
    final counter = EmptyDirectoryCounter(root.path);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      counter.visit(entity);
    }
    expect(counter.count, Platform.isWindows ? 2 : 1);
    expect(await File(p.join(root.path, 'files', 'zero')).length(), 0);
  });
  test('overlapping dropped roots count the same empty leaf once and failure reports no partial count', () async {
    final leaf = Directory(p.join(root.path, 'empty'));
    await leaf.create();
    int? count;
    expect(await collectDroppedFiles([root.path, leaf.path, root.path], onEmptyDirectories: (value) => count = value), isEmpty);
    expect(count, 1);
    count = null;
    await expectLater(
      collectDroppedFiles([root.path, p.join(root.path, 'missing')], onEmptyDirectories: (value) => count = value),
      throwsA(isA<FileSystemException>()),
    );
    expect(count, isNull);
  });
  test('failed enumeration never reports a partial empty-directory success', () async {
    int? count;
    await expectLater(
      readDirectoryFiles(p.join(root.path, 'missing'), onEmptyDirectories: (value) => count = value),
      throwsA(isA<FileSystemException>()),
    );
    expect(count, isNull);
  });
}
