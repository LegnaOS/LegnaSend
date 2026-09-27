import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';

class _Api extends RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Directory extends Fake implements Directory {
  @override
  final String path;
  final _Filesystem fs;
  _Directory(this.path, this.fs);
  @override
  void createSync({bool recursive = false}) {
    fs.syncCalls++;
    throw StateError('Synchronous directory I/O blocks the receive event loop');
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    fs.started.add(path);
    await fs.gates[path]?.future;
    if (fs.errors.contains(path)) throw FileSystemException('fixture permission denied', path);
    fs.directories.add(path);
    return this;
  }
}

class _Filesystem {
  final gates = <String, Completer<void>>{};
  final errors = <String>{};
  final typeGates = <String, Completer<void>>{};
  final typeCalls = <String>[];
  final links = <String>{};
  final directories = <String>{};
  final started = <String>[];
  int syncCalls = 0;
  Future<T> run<T>(Future<T> Function() body) => IOOverrides.runZoned(
    body,
    createDirectory: (path) => _Directory(path, this),
    fseGetType: (path, followLinks) async {
      expect(followLinks, false);
      typeCalls.add(path);
      await typeGates[path]?.future;
      if (links.contains(path)) return FileSystemEntityType.link;
      return directories.contains(path) ? FileSystemEntityType.directory : FileSystemEntityType.notFound;
    },
    fseGetTypeSync: (path, followLinks) {
      syncCalls++;
      throw StateError('Synchronous type I/O blocks the receive event loop');
    },
  );
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  test('a slow directory operation yields the receive isolate and releases a cancelled target', () async {
    final fs = _Filesystem();
    fs.gates['/destination'] = Completer<void>();
    var active = true;
    Object? failure;
    FileSaveTarget? target;
    final operation = fs
        .run(
          () => prepareReceiveTargetIfActive(
            isActive: () => active,
            prepare: () => prepareFileSaveTarget(
              destinationDirectory: '/destination',
              cacheDirectory: '/cache',
              fileName: 'file.bin',
              saveToGallery: false,
              isImage: false,
              createdDirectories: {},
              reservations: ReceivePathReservations(),
            ),
          ),
        )
        .then<void>(
          (value) {
            target = value;
          },
          onError: (Object error) {
            failure = error;
          },
        );
    await Future<void>.delayed(Duration.zero);
    active = false; // The independent server event loop can process cancellation.
    fs.gates['/destination']!.complete();
    await operation;
    expect(failure, isNull, reason: 'Destination preparation must not invoke synchronous filesystem APIs');
    expect(fs.syncCalls, 0);
    expect(fs.started, ['/destination']);
    expect(target, isNull);
  });

  Future<FileSaveTarget?> guarded(_Filesystem fs, String name, bool Function() active, {ReceivePathReservations? reservations}) => fs.run(
    () => prepareReceiveTargetIfActive(
      isActive: active,
      prepare: () => prepareFileSaveTarget(
        destinationDirectory: '/destination',
        cacheDirectory: '/cache',
        fileName: name,
        saveToGallery: false,
        isImage: false,
        createdDirectories: {},
        reservations: reservations ?? ReceivePathReservations(),
        isActive: active,
      ),
    ),
  );
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('cancellation during root creation stops all subsequent peer directory work', () async {
    final fs = _Filesystem();
    fs.gates['/destination'] = Completer<void>();
    var active = true;
    final result = guarded(fs, 'outer/inner/file.bin', () => active);
    await flush();
    expect(fs.started, ['/destination']);
    active = false;
    fs.gates['/destination']!.complete();
    expect(await result, isNull);
    expect(fs.started, ['/destination']);
    expect(fs.directories, {'/destination'}, reason: 'The already submitted OS mkdir may finish; it is not deleted');
  });

  test('cancellation during nofollow type check never submits that child mkdir', () async {
    final fs = _Filesystem();
    fs.typeGates['/destination/outer'] = Completer<void>();
    var active = true;
    final result = guarded(fs, 'outer/inner/file.bin', () => active);
    await flush();
    expect(fs.typeCalls, contains('/destination/outer'));
    active = false;
    fs.typeGates['/destination/outer']!.complete();
    expect(await result, isNull);
    expect(fs.started, ['/destination']);
  });

  test('cancellation during submitted child mkdir stops deeper creation without guessed rollback', () async {
    final fs = _Filesystem();
    fs.gates['/destination/outer'] = Completer<void>();
    var active = true;
    final result = guarded(fs, 'outer/inner/file.bin', () => active);
    await flush();
    expect(fs.started, ['/destination', '/destination/outer']);
    active = false;
    fs.gates['/destination/outer']!.complete();
    expect(await result, isNull);
    expect(fs.directories, {'/destination', '/destination/outer'});
    expect(fs.started, isNot(contains('/destination/outer/inner')));
  });

  test('cancellation during final name I/O does not retain a stale filename reservation', () async {
    final fs = _Filesystem();
    fs.typeGates['/destination/file.bin'] = Completer<void>();
    var active = true;
    final names = ReceivePathReservations();
    final result = guarded(fs, 'file.bin', () => active, reservations: names);
    await flush();
    active = false;
    fs.typeGates['/destination/file.bin']!.complete();
    expect(await result, isNull);
    expect(names.contains('/destination/file.bin'), false);
    active = true;
    expect((await guarded(fs, 'file.bin', () => active, reservations: names))!.path, '/destination/file.bin');
  });

  test('concurrent sibling files share one pending directory creation and both complete', () async {
    final fs = _Filesystem();
    fs.gates['/destination/outer'] = Completer<void>();
    final names = ReceivePathReservations();
    final first = guarded(fs, 'outer/one.bin', () => true, reservations: names);
    final second = guarded(fs, 'outer/two.bin', () => true, reservations: names);
    await flush();
    expect(fs.started.where((path) => path == '/destination/outer'), hasLength(1));
    fs.gates['/destination/outer']!.complete();
    expect((await first)!.path, '/destination/outer/one.bin');
    expect((await second)!.path, '/destination/outer/two.bin');
    expect(fs.syncCalls, 0);
  });

  test('in-flight directory owns its name while a concurrent file chooses a numbered sibling', () async {
    final fs = _Filesystem();
    fs.gates['/destination/outer'] = Completer<void>();
    final names = ReceivePathReservations();
    final nested = guarded(fs, 'outer/file.bin', () => true, reservations: names);
    await flush();
    final file = await guarded(fs, 'outer', () => true, reservations: names);
    expect(file!.path, '/destination/outer (2)');
    fs.gates['/destination/outer']!.complete();
    expect((await nested)!.path, '/destination/outer/file.bin');
  });

  test('directory claim acquired during filename I/O is rechecked before reserving the name', () async {
    final stat = Completer<FileSystemEntityType>();
    final names = ReceivePathReservations(entryType: (path) async => path.endsWith('/outer') ? stat.future : FileSystemEntityType.notFound);
    final file = names.allocate(directory: '/destination', fileName: 'outer');
    final creation = Completer<void>();
    final directory = names.prepareDirectory(path: '/destination/outer', prepare: (_) => creation.future);
    stat.complete(FileSystemEntityType.notFound);
    expect(await file, '/destination/outer (2)');
    creation.complete();
    await directory;
  });

  test('permission failure releases shared directory claim for a later valid attempt', () async {
    final fs = _Filesystem()..errors.add('/destination/outer');
    final names = ReceivePathReservations();
    await expectLater(guarded(fs, 'outer/file.bin', () => true, reservations: names), throwsA(isA<FileSystemException>()));
    fs.errors.clear();
    expect((await guarded(fs, 'outer/file.bin', () => true, reservations: names))!.path, '/destination/outer/file.bin');
  });

  test('after mkdir the child type is checked without following a replacement link', () async {
    final fs = _Filesystem();
    fs.gates['/destination/outer'] = Completer<void>();
    final result = guarded(fs, 'outer/deeper/file.bin', () => true);
    final expectation = expectLater(result, throwsA(isA<FileSystemException>()));
    await flush();
    fs.links.add('/destination/outer');
    fs.gates['/destination/outer']!.complete();
    await expectation;
    expect(fs.started, ['/destination', '/destination/outer']);
  });
  test('shared directory work survives cancellation of its first caller for a live sibling', () async {
    final fs = _Filesystem();
    fs.typeGates['/destination/outer'] = Completer<void>();
    final names = ReceivePathReservations();
    var firstActive = true;
    final first = guarded(fs, 'outer/one.bin', () => firstActive, reservations: names);
    await flush();
    final second = guarded(fs, 'outer/two.bin', () => true, reservations: names);
    final both = Future.wait([first, second]);
    await flush();
    firstActive = false;
    fs.typeGates['/destination/outer']!.complete();
    final results = await both;
    expect(results.first, isNull);
    expect(results.last!.path, '/destination/outer/two.bin');
    expect(fs.started.where((path) => path == '/destination/outer'), hasLength(1));
  });

  test('completed directory claim prevents a previously sampled notFound from reserving that name', () async {
    final stat = Completer<FileSystemEntityType>();
    final names = ReceivePathReservations(entryType: (path) async => path.endsWith('/outer') ? stat.future : FileSystemEntityType.notFound);
    final file = names.allocate(directory: '/destination', fileName: 'outer');
    await names.prepareDirectory(path: '/destination/outer', prepare: (_) async {});
    stat.complete(FileSystemEntityType.notFound);
    expect(await file, '/destination/outer (2)');
  });
  test('shared directory preparation stops before mkdir when every waiting caller has cancelled', () async {
    final fs = _Filesystem();
    fs.typeGates['/destination/outer'] = Completer<void>();
    final names = ReceivePathReservations();
    var firstActive = true;
    var secondActive = true;
    final first = guarded(fs, 'outer/one.bin', () => firstActive, reservations: names);
    final second = guarded(fs, 'outer/two.bin', () => secondActive, reservations: names);
    final both = Future.wait([first, second]);
    await flush();
    firstActive = secondActive = false;
    fs.typeGates['/destination/outer']!.complete();
    expect(await both, [null, null]);
    expect(fs.started, ['/destination']);
  });
}
