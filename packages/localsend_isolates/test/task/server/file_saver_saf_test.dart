import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';

const channel = MethodChannel('org.localsend.localsend_app/localsend');
const tree = 'content://cloud.provider/tree/root%3Aopaque';
const resolved = '$tree/document/db-key%3A72';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUpAll(() => RustLib.initMock(api: _Api()));
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'resolveReceiveDirectory') return resolved;
      if (call.method == 'createFile') return {'uri': '$tree/document/db-key%3A999', 'fd': 71};
      throw StateError('Unexpected ${call.method}');
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('nested SAF receives use actual parent and created document IDs', () async {
    final target = await prepareFileSaveTarget(
      destinationDirectory: tree,
      cacheDirectory: '/unused',
      fileName: '中文 %/inner/file.txt',
      saveToGallery: false,
      isImage: false,
      createdDirectories: {},
      androidSdkInt: 36,
    );
    expect(calls.map((c) => c.method), ['resolveReceiveDirectory', 'createFile']);
    expect(calls.first.arguments, {
      'treeUri': tree,
      'components': ['中文 %', 'inner'],
    });
    expect(calls.last.arguments['parentUri'], resolved);
    expect(calls.last.arguments['fileName'], 'file.txt');
    expect(target.displayPath, '$tree/document/db-key%3A999');
    expect(target.fileDescriptor, 71);
    expect(target.path, isNull);
  });
  test('root file still revalidates persisted grant and actual provider root', () async {
    await digestFilePathAndPrepareDirectory(parentDirectory: tree, fileName: 'plain.txt', createdDirectories: {'old'});
    expect(calls.single.arguments, {'treeUri': tree, 'components': []});
  });
  test('each attempt resolves again instead of trusting old created-directory flags', () async {
    final directories = {'folder'};
    for (var i = 0; i < 2; i++) {
      await digestFilePathAndPrepareDirectory(parentDirectory: tree, fileName: 'folder/a.txt', createdDirectories: directories);
    }
    expect(calls.length, 2);
  });
  for (final code in ['PERMISSION_DENIED', 'DIRECTORY_UNAVAILABLE', 'NAME_CONFLICT', 'CREATE_FAILED', 'BUSY']) {
    test('$code stops before opening a file, without fallback or swallowed error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(code: code);
      });
      await expectLater(
        prepareFileSaveTarget(
          destinationDirectory: tree,
          cacheDirectory: '/unused',
          fileName: 'folder/file.txt',
          saveToGallery: false,
          isImage: false,
          createdDirectories: {},
          androidSdkInt: 36,
        ),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
      );
      expect(calls.single.method, 'resolveReceiveDirectory');
    });
  }
  test('invalid native response fails instead of fabricating an URI', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => '/not/a/content/uri');
    await expectLater(digestFilePathAndPrepareDirectory(parentDirectory: tree, fileName: 'x', createdDirectories: {}), throwsStateError);
  });
  test('path traversal rejected before calling the provider', () async {
    await expectLater(
      digestFilePathAndPrepareDirectory(parentDirectory: tree, fileName: '../x', createdDirectories: {}),
      throwsA('Path traversal detected'),
    );
    expect(calls, isEmpty);
  });
}

class _Api implements RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
