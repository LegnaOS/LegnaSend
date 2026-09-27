import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:localsend_isolates/src/task/server/receive_resume_capability.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';
import 'package:path/path.dart' as p;

class _Api extends RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  const receipt = '11111111-1111-4111-8111-111111111111';
  setUpAll(() => RustLib.initMock(api: _Api()));
  setUp(() => directory = Directory.systemTemp.createTempSync('legna-durable-target-'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('approved lookup precedes numbering and keeps existing owned publication untouched', () async {
    final child = Directory(p.join(directory.path, 'child'))..createSync();
    final published = File(p.join(child.path, 'file (2).txt'))..writeAsStringSync('already published');
    File(p.join(child.path, 'file.txt')).writeAsStringSync('user original');
    var called = false;
    final target = await prepareFileSaveTarget(
      destinationDirectory: directory.path,
      cacheDirectory: p.join(directory.path, 'cache'),
      fileName: 'child/file.txt',
      saveToGallery: false,
      isImage: false,
      createdDirectories: {},
      reservations: ReceivePathReservations(),
      receiveFileId: 'file',
      recoveryLookup: ({required approvedDirectory, required requestedName}) async {
        called = true;
        expect(approvedDirectory, directory.path);
        expect(requestedName, 'child/file.txt');
        return ReceiveRecoveryTarget(path: published.path, receiptId: receipt, completedUnixMs: 1000);
      },
    );
    expect(called, isTrue);
    expect(target.path, published.path);
    expect(target.recovery!.receiptId, receipt);
    expect(target.recovery!.completedAt!.millisecondsSinceEpoch, 1000);
    expect(published.readAsStringSync(), 'already published');
    expect(File(p.join(child.path, 'file.txt')).readAsStringSync(), 'user original');
    expect(File(p.join(child.path, 'file (3).txt')).existsSync(), isFalse);
  });
  test('null candidate follows original numbering but carries core-owned future receipt identity', () async {
    File(p.join(directory.path, 'file.txt')).writeAsStringSync('keep');
    final target = await prepareFileSaveTarget(
      destinationDirectory: directory.path,
      cacheDirectory: p.join(directory.path, 'cache'),
      fileName: 'file.txt',
      saveToGallery: false,
      isImage: false,
      createdDirectories: {},
      receiveFileId: 'file',
      recoveryLookup: ({required approvedDirectory, required requestedName}) async => ReceiveRecoveryTarget(path: null, receiptId: receipt),
    );
    expect(target.path, p.join(directory.path, 'file (2).txt'));
    expect(target.recovery!.receiptId, receipt);
  });
  test('same file may reclaim its target; a different file cannot steal its recovery reservation', () async {
    final names = ReceivePathReservations();
    final target = p.join(directory.path, 'same.txt');
    names.reserveRecovery(path: target, owner: 'one');
    names.reserveRecovery(path: target, owner: 'one');
    expect(() => names.reserveRecovery(path: target, owner: 'two'), throwsA(isA<FileSystemException>()));
    final allocated = await names.allocate(directory: directory.path, fileName: 'another.txt', owner: 'three');
    names.reserveRecovery(path: allocated, owner: 'three');
    expect(() => names.reserveRecovery(path: allocated, owner: 'four'), throwsA(isA<FileSystemException>()));
  });
  test('late lookup after cancellation cannot reserve a path or allocate a numbered replacement', () async {
    final names = ReceivePathReservations(), gate = Completer<ReceiveRecoveryTarget>();
    var active = true;
    final ready = Completer<void>();
    final target = p.join(directory.path, 'file.txt');
    final operation = digestFilePathAndPrepareDirectory(
      parentDirectory: directory.path,
      fileName: 'file.txt',
      createdDirectories: {},
      reservations: names,
      reservationOwner: 'file',
      isActive: () => active,
      recoveryLookup: ({required approvedDirectory, required requestedName}) {
        ready.complete();
        return gate.future;
      },
    );
    await ready.future;
    active = false;
    gate.complete(ReceiveRecoveryTarget(path: target, receiptId: receipt));
    await expectLater(operation, throwsStateError);
    expect(names.contains(target), isFalse);
    expect(File(target).existsSync(), isFalse);
  });
  test('lookup failure or out-of-directory candidate fails rather than falling back to numbering', () async {
    for (final badPath in [false, true]) {
      await expectLater(
        digestFilePathAndPrepareDirectory(
          parentDirectory: directory.path,
          fileName: 'file.txt',
          createdDirectories: {},
          reservationOwner: 'file',
          recoveryLookup: ({required approvedDirectory, required requestedName}) async {
            if (!badPath) throw StateError('Invalid owned record');
            return ReceiveRecoveryTarget(path: p.join(directory.parent.path, 'outside.txt'), receiptId: receipt);
          },
        ),
        badPath ? throwsFormatException : throwsStateError,
      );
    }
    expect(File(p.join(directory.path, 'file.txt')).existsSync(), isFalse);
  });
  test('gallery and cache targets skip durable lookup while normal persistent capability remains', () async {
    var calls = 0;
    for (final gallery in [false, true]) {
      final cache = p.join(directory.path, 'cache');
      final target = await prepareFileSaveTarget(
        destinationDirectory: gallery ? directory.path : cache,
        cacheDirectory: cache,
        fileName: 'file.txt',
        saveToGallery: gallery,
        isImage: gallery,
        createdDirectories: {},
        receiveFileId: 'file',
        recoveryLookup: ({required approvedDirectory, required requestedName}) async {
          calls++;
          return ReceiveRecoveryTarget(path: null, receiptId: receipt);
        },
      );
      expect(target.recovery, isNull);
    }
    expect(calls, 0);
    List<String> capability(String path, {bool gallery = false, int? sdk}) => durableReceiveFileIds(
      destinationDirectory: path,
      cacheDirectory: '/cache',
      saveToGallery: gallery,
      androidSdkInt: sdk,
      acceptedIds: ['file'],
      sizes: {'file': 1048576},
    );
    expect(capability('/downloads'), ['file']);
    for (final path in ['/cache', '/cache/temporary', 'relative', 'content://provider/tree/root']) {
      expect(capability(path), isEmpty);
    }
    expect(capability('/downloads', gallery: true), isEmpty);
    expect(capability('/storage/ABCD-1234/Download', sdk: 35), isEmpty);
  });
  test('capability probe is bounded per approval parent and stops after session invalidation', () async {
    final calls = <String>[];
    final result = await probeDurableReceiveFileIds(
      approvedDirectory: directory.path,
      candidates: ['a', 'b', 'c', 'd'],
      approvedNames: {'a': 'one/a', 'b': 'one/b', 'c': 'two/c', 'd': 'three/d'},
      maxParents: 2,
      probe: ({required approvedDirectory, required requestedName}) async {
        calls.add(requestedName);
        return !requestedName.startsWith('two/');
      },
      isActive: () => true,
    );
    expect(result, ['a', 'b']);
    expect(calls, ['one/a', 'two/c']);
    var active = true;
    final late = await probeDurableReceiveFileIds(
      approvedDirectory: directory.path,
      candidates: ['a', 'b'],
      approvedNames: {'a': 'a', 'b': 'b'},
      probe: ({required approvedDirectory, required requestedName}) async {
        active = false;
        return true;
      },
      isActive: () => active,
    );
    expect(late, isEmpty);
  });
}
