import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUpAll(() => RustLib.initMock(api: _Api()));
  setUp(() => root = Directory.systemTemp.createTempSync('legnasend-receive-names-'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<String> prepare(String name, {ReceivePathReservations? reservations}) async =>
      (await digestFilePathAndPrepareDirectory(parentDirectory: root.path, fileName: name, createdDirectories: {}, reservations: reservations)).$1;

  test('existing directory occupies a candidate name and is preserved', () async {
    final existing = Directory(p.join(root.path, 'file.txt'))..createSync();
    final content = File(p.join(existing.path, 'keep'))..writeAsStringSync('keep');
    expect(await prepare('file.txt'), p.join(root.path, 'file (2).txt'));
    expect(content.readAsStringSync(), 'keep');
  });
  test('5000 pending identical names get distinct reservations before any publication', () async {
    final reservations = ReceivePathReservations();
    final paths = await Future.wait(List.generate(5000, (_) => prepare('中文 %.txt', reservations: reservations)));
    expect(paths.toSet(), hasLength(5000));
    expect(paths.first, p.join(root.path, '中文 %.txt'));
    expect(paths.last, p.join(root.path, '中文 % (5000).txt'));
    expect(root.listSync(), isEmpty, reason: 'reserving does not create final files');
  });
  test('overlapping original and numbered names do not converge under concurrency', () async {
    final reservations = ReceivePathReservations();
    final paths = await Future.wait([
      for (var n = 0; n < 40; n++) prepare(n.isEven ? 'a.txt' : 'a (2).txt', reservations: reservations),
    ]);
    expect(paths.toSet(), hasLength(40));
  });
  test('session name reservation respects configured case handling but preserves spelling', () async {
    final reservations = ReceivePathReservations(caseInsensitive: true);
    expect(await prepare('Alpha.TXT', reservations: reservations), p.join(root.path, 'Alpha.TXT'));
    expect(await prepare('alpha.txt', reservations: reservations), p.join(root.path, 'alpha (2).txt'));
  });
  test('separate sessions do not retain stale uncommitted reservations', () async {
    expect(await prepare('a.txt', reservations: ReceivePathReservations()), p.join(root.path, 'a.txt'));
    expect(await prepare('a.txt', reservations: ReceivePathReservations()), p.join(root.path, 'a.txt'));
  });
  test('whole-file retry retains its previously reserved destination', () async {
    final reservations = ReceivePathReservations();
    final target = await prepareFileSaveTarget(
      destinationDirectory: root.path,
      cacheDirectory: root.path,
      fileName: 'file.txt',
      saveToGallery: false,
      isImage: false,
      createdDirectories: {},
      reservations: reservations,
    );
    expect(await reopenFileSaveTarget(target), same(target));
    expect(await prepare('file.txt', reservations: reservations), p.join(root.path, 'file (2).txt'));
  });
  test('pending file cannot be reused as an incoming directory', () async {
    final reservations = ReceivePathReservations();
    await prepare('folder', reservations: reservations);
    await expectLater(prepare('folder/a.txt', reservations: reservations), throwsA(isA<FileSystemException>()));
    expect(root.listSync(), isEmpty);
  });
  test('existing file in a directory component fails before deeper creation', () async {
    final file = File(p.join(root.path, 'folder'))..writeAsStringSync('keep');
    await expectLater(prepare('folder/deeper/a.txt'), throwsA(isA<FileSystemException>()));
    expect(file.readAsStringSync(), 'keep');
  });
  test('failed allocator call releases its name queue for a later retry', () async {
    var failed = false;
    final reservations = ReceivePathReservations(
      entryType: (_) async {
        if (!failed) {
          failed = true;
          throw const FileSystemException('storage unavailable');
        }
        return FileSystemEntityType.notFound;
      },
    );
    await expectLater(reservations.allocate(directory: root.path, fileName: 'same.txt'), throwsA(isA<FileSystemException>()));
    expect(await reservations.allocate(directory: root.path, fileName: 'same.txt'), p.join(root.path, 'same.txt'));
  });
  if (!Platform.isWindows) {
    test('dangling and live final symlinks occupy names without touching their targets', () async {
      final outside = File(p.join(root.path, 'source'))..writeAsStringSync('keep');
      Link(p.join(root.path, 'live.txt')).createSync(outside.path);
      Link(p.join(root.path, 'dangling.txt')).createSync(p.join(root.path, 'absent'));
      expect(await prepare('live.txt'), p.join(root.path, 'live (2).txt'));
      expect(await prepare('dangling.txt'), p.join(root.path, 'dangling (2).txt'));
      expect(outside.readAsStringSync(), 'keep');
      expect(File(p.join(root.path, 'absent')).existsSync(), false);
    });
    test('peer subdirectory links are rejected before creating any outside descendants', () async {
      final outside = Directory.systemTemp.createTempSync('legnasend-outside-');
      try {
        Link(p.join(root.path, 'linked')).createSync(outside.path);
        await expectLater(prepare('linked/new/deeper/file.txt'), throwsA(isA<FileSystemException>()));
        expect(outside.listSync(), isEmpty);
      } finally {
        outside.deleteSync(recursive: true);
      }
    });
    test('even in-root descendant links are not silently followed', () async {
      final actual = Directory(p.join(root.path, 'actual'))..createSync();
      Link(p.join(root.path, 'alias')).createSync(actual.path);
      await expectLater(prepare('alias/file.txt'), throwsA(isA<FileSystemException>()));
      expect(actual.listSync(), isEmpty);
    });
  }
}

class _Api implements RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
