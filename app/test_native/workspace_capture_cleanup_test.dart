@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:localsend_isolates/rust/api/server.dart' as native;
import 'package:path/path.dart' as p;

import '../../packages/localsend_isolates/test/support/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeWorkspaceNativeBridge(Directory.current.parent.path));
  WorkspaceCaptureStore store(Directory root) => WorkspaceCaptureStore(
    root,
    removeStage: (root, id) => native.cleanupWorkspaceCapture(root: root, id: id),
  );
  test('production native deletion preserves active exports and unknown files', () async {
    final root = await Directory.systemTemp.createTemp('native-capture-cleanup-');
    final value = store(root);
    try {
      final live = await value.create(2);
      await File(p.join(live.directory.path, 'source-0')).writeAsString('original bytes');
      expect((await value.cleanup()).active, 1);
      await live.release();
      expect(await live.directory.exists(), false);
      expect(value.lastCleanup.unlinkedBytes, 14);
      final retained = await value.create(1);
      await File(p.join(retained.directory.path, 'user-file')).writeAsString('keep');
      await expectLater(retained.release(), throwsStateError);
      expect(await File(p.join(retained.directory.path, 'user-file')).readAsString(), 'keep');
    } finally {
      await value.close();
      await root.delete(recursive: true);
    }
  });
  final dart = Platform.environment['LEGNASEND_DART_EXECUTABLE'];
  test(
    'real SIGKILL releases owner lock and restarted native cleanup removes registered bytes',
    () async {
      final parent = await Directory.systemTemp.createTemp('native-capture-kill-');
      final root = Directory(p.join(parent.path, 'exports 中文'));
      final child = await Process.start(dart!, [
        '--packages=${p.join(Directory.current.parent.path, '.dart_tool/package_config.json')}',
        p.join(Directory.current.path, 'test/support/workspace_capture_process.dart'),
        '--owner',
        root.path,
      ]);
      final errors = child.stderr.transform(utf8.decoder).join();
      final value = store(root);
      try {
        final line = await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 20));
        final created = jsonDecode(line) as Map;
        final stage = Directory(created['stage'] as String);
        await expectLater(value.initialize(), throwsA(isA<FileSystemException>()));
        expect(await stage.exists(), true);
        expect(child.kill(ProcessSignal.sigkill), true);
        await child.exitCode.timeout(const Duration(seconds: 10));
        expect(await errors, isEmpty);
        await value.initialize();
        expect(await stage.exists(), false);
        expect(value.lastCleanup.removedStages, 1);
        expect(value.lastCleanup.unlinkedBytes, 1024 * 1024);
      } finally {
        child.kill(ProcessSignal.sigkill);
        await value.close();
        await parent.delete(recursive: true);
      }
    },
    skip: dart == null ? 'Set LEGNASEND_DART_EXECUTABLE to the pinned Dart VM for real process termination acceptance' : false,
  );
}
