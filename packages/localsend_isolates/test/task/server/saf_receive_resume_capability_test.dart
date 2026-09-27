import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/receive_resume_capability.dart';

const _channel = MethodChannel('org.localsend.localsend_app/localsend');
const _tree = 'content://provider/tree/root%3Aopaque';
const _tx = 'c5e8e2cf-038c-4cd2-ae10-1c845b607281';
const _lease = '8f5f0482-dfed-4f28-a2dc-77c550c2b038';

class _Api implements RustLibApi {
  final List<int> closed = [];
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    if (fileDescriptor != null) closed.add(fileDescriptor);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  late List<MethodCall> calls;
  late bool active;
  late int probes;
  late bool supported;
  Object? probeError;
  Object? prepareError;
  Object? cleanupError;
  Completer<bool>? probeGate;
  Completer<void>? preparationGate;
  final seenDirectories = <Set<String>>[];
  setUp(() {
    active = true;
    probes = 0;
    supported = true;
    probeError = null;
    prepareError = null;
    cleanupError = null;
    probeGate = null;
    preparationGate = null;
    calls = [];
    seenDirectories.clear();
    api.closed.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'beginSafReceiveTransaction' && prepareError != null) throw prepareError!;
      if (call.method == 'releaseSafReceiveTransaction' && cleanupError != null) throw cleanupError!;
      return switch (call.method) {
        'resolveReceiveDirectory' => '$_tree/document/parent%3Aid',
        'beginSafReceiveTransaction' => {
          'transactionId': _tx,
          'state': 'ready',
          'cacheUri': '$_tree/document/cache',
          'stagingUri': '$_tree/document/staging',
          'capabilities': {'readWrite': true, 'seek': true, 'length': true, 'lock': true},
        },
        'openSafReceiveTransaction' => {'transactionId': _tx, 'lease': _lease, 'cacheFd': 71, 'stagingFd': 72},
        'releaseSafReceiveTransaction' || 'abortSafReceiveTransaction' => {'transactionId': _tx, 'complete': true, 'deleted': [], 'retained': []},
        _ => throw StateError('Unexpected ${call.method}'),
      };
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  Future<List<String>> run({
    String destination = _tree,
    bool gallery = false,
    int? sdk = 36,
    List<String> ids = const ['one', 'two', 'other', 'small', 'unknown'],
    Map<String, String> names = const {'one': 'folder/a.bin', 'two': 'folder/b.bin', 'other': 'different/c.bin', 'small': 'small.bin'},
    Map<String, int> sizes = const {'one': 1048576, 'two': 2097152, 'other': 1048576, 'small': 1048575},
    int maxParents = 64,
  }) => probeSafResumableReceiveFileIds(
    destinationDirectory: destination,
    cacheDirectory: '/unused',
    sessionId: 'session',
    saveToGallery: gallery,
    androidSdkInt: sdk,
    acceptedIds: ids,
    sizes: sizes,
    approvedNames: names,
    isActive: () => active,
    maxParents: maxParents,
    prepare: ({required fileId, required fileName, required createdDirectories}) async {
      seenDirectories.add(createdDirectories);
      final target = await prepareFileSaveTarget(
        destinationDirectory: _tree,
        cacheDirectory: '/unused',
        fileName: fileName,
        saveToGallery: false,
        isImage: false,
        createdDirectories: createdDirectories,
        androidSdkInt: 36,
        receiveSessionId: 'session',
        receiveFileId: fileId,
      );
      await preparationGate?.future;
      return target;
    },
    probe: ({required cacheDescriptor, required stagingDescriptor}) async {
      probes++;
      expect(cacheDescriptor, 71);
      expect(stagingDescriptor, 72);
      if (probeError != null) throw probeError!;
      return probeGate != null ? await probeGate!.future : supported;
    },
  );

  test('real SAF preparation per relative parent, local bookkeeping, descriptors consumed and transactions released', () async {
    expect(await run(), ['one', 'two', 'other']);
    expect(probes, 2);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction').length, 2);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction').every((c) => c.arguments['published'] == false), true);
    expect(api.closed, isEmpty, reason: 'the native probe owns both descriptors');
    expect(seenDirectories.length, 2);
    expect(identical(seenDirectories.first, seenDirectories.last), true);
    final previous = seenDirectories.first;
    await run(ids: ['one']);
    expect(identical(previous, seenDirectories.last), false, reason: 'approval caches never leak into another approval');
  });

  test('Android content URI, no gallery, accepted size at least one MiB required', () async {
    expect(await run(destination: '/downloads'), isEmpty);
    expect(await run(sdk: null), isEmpty);
    expect(await run(gallery: true), isEmpty);
    expect(await run(ids: ['small', 'unknown']), isEmpty);
    expect(probes, 0);
    expect(calls, isEmpty);
  });

  test('unsupported or throwing descriptor probe releases and only disables that parent', () async {
    supported = false;
    expect(await run(), isEmpty);
    expect(probes, 2);
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction').length, 2);
    probeError = StateError('revoked');
    expect(await run(ids: ['one']), isEmpty);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
    expect(api.closed, isEmpty);
  });

  test('preparation or cleanup failure never advertises capability', () async {
    prepareError = PlatformException(code: 'GRANT_REVOKED');
    expect(await run(), isEmpty);
    expect(probes, 0);
    expect(calls.where((c) => c.method == 'beginSafReceiveTransaction').length, 2);
    prepareError = null;
    cleanupError = PlatformException(code: 'PROVIDER_UNAVAILABLE');
    expect(await run(ids: ['one']), isEmpty);
    expect(probes, 1);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
    expect(api.closed, isEmpty);
  });

  test('session replacement during probe returns empty after cleanup', () async {
    probeGate = Completer<bool>();
    final result = run();
    while (probes == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls.where((c) => c.method == 'releaseSafReceiveTransaction'), isEmpty, reason: 'native probe must drain before release');
    active = false;
    probeGate!.complete(true);
    expect(await result, isEmpty);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
    expect(probes, 1);
  });

  test('session replacement during prepare closes unhanded descriptors before cleanup', () async {
    preparationGate = Completer<void>();
    final result = run();
    while (!calls.any((c) => c.method == 'openSafReceiveTransaction')) {
      await Future<void>.delayed(Duration.zero);
    }
    active = false;
    preparationGate!.complete();
    expect(await result, isEmpty);
    expect(probes, 0);
    expect(api.closed, [71, 72]);
    expect(calls.last.method, 'releaseSafReceiveTransaction');
  });

  test('synchronous descriptor bridge failure retains journal without guessed close or release', () async {
    final target = await prepareFileSaveTarget(
      destinationDirectory: _tree,
      cacheDirectory: '/unused',
      fileName: 'file.bin',
      saveToGallery: false,
      isImage: false,
      createdDirectories: {},
      androidSdkInt: 36,
      receiveSessionId: 'session',
      receiveFileId: 'file',
    );
    await expectLater(
      target.saf!.probeDescriptors(
        probe: ({required cacheDescriptor, required stagingDescriptor}) => throw StateError('bridge unavailable'),
        isActive: () => true,
      ),
      throwsStateError,
    );
    expect(api.closed, isEmpty);
    expect(calls.where((call) => call.method == 'releaseSafReceiveTransaction'), isEmpty);
  });

  test('parent budget, invalid paths and SAF durable exclusion', () async {
    expect(await run(maxParents: 1), ['one', 'two']);
    expect(probes, 1);
    expect(await run(ids: ['one'], names: {'one': '../escape.bin'}), isEmpty);
    expect(
      durableReceiveFileIds(
        destinationDirectory: _tree,
        cacheDirectory: '/unused',
        saveToGallery: false,
        androidSdkInt: 36,
        acceptedIds: ['one'],
        sizes: {'one': 2097152},
      ),
      isEmpty,
    );
    final ids = List.generate(65, (i) => '$i');
    probes = 0;
    final accepted = await run(
      ids: ids,
      names: {for (final id in ids) id: 'parent$id/file'},
      sizes: {for (final id in ids) id: 2097152},
      maxParents: 1000,
    );
    expect(accepted.length, 64);
    expect(probes, 64);
  });
}
