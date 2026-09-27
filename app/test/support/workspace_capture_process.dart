// Run with the pinned Dart VM; this deliberately avoids Flutter dependencies.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:path/path.dart' as p;

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  if (args.firstOrNull == '--owner') {
    final store = WorkspaceCaptureStore.leaseProbe(Directory(args[1]));
    final lease = await store.create(2);
    final file = File(p.join(lease.directory.path, 'source-0'));
    await file.writeAsBytes(List.filled(1024 * 1024, 37), flush: true);
    stdout.writeln(jsonEncode({'stage': lease.directory.path, 'bytes': await file.length()}));
    await stdout.flush();
    await stdin.drain<void>(); // Keep the owned child alive until its parent kills it.
    return;
  }
  final parent = await Directory.systemTemp.createTemp('capture-process-proof-');
  final root = Directory(p.join(parent.path, 'private captures 中文'));
  Process? child;
  WorkspaceCaptureStore? next;
  try {
    final args = [
      '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
      Platform.script.toFilePath(),
      '--owner',
      root.path,
    ];
    child = await Process.start(Platform.resolvedExecutable, args);
    final errors = child.stderr.transform(utf8.decoder).join();
    final line = await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 20));
    final value = jsonDecode(line) as Map<String, dynamic>;
    final stage = Directory(value['stage'] as String);
    require(await File(p.join(stage.path, 'source-0')).length() == 1024 * 1024, 'child did not flush source');
    final contender = WorkspaceCaptureStore.leaseProbe(root);
    var denied = false;
    try {
      await contender.initialize();
    } catch (_) {
      denied = true;
    } finally {
      await contender.close();
    }
    require(denied, 'live process lock was not enforced');
    require(await stage.exists(), 'live stage removed');
    require(child.kill(ProcessSignal.sigkill), 'failed to kill owned child');
    final exit = await child.exitCode.timeout(const Duration(seconds: 10));
    final stderr = await errors;
    require(stderr.isEmpty, 'child error: $stderr');
    next = WorkspaceCaptureStore.leaseProbe(root);
    await next.initialize();
    require(!await stage.exists(), 'interrupted registered stage survived restart');
    require(next.lastCleanup.removedStages == 1 && next.lastCleanup.unlinkedBytes == 1024 * 1024, 'incorrect cleanup accounting');
    stdout.writeln(
      jsonEncode({
        'platform': Platform.operatingSystem,
        'childExit': exit,
        'liveProcessProtected': true,
        'restartCleanup': next.lastCleanup.toJson(),
        'scope': 'real session lease and child SIGKILL; standalone Dart removal; native deletion verified separately',
      }),
    );
  } finally {
    child?.kill(ProcessSignal.sigkill);
    await next?.close();
    await parent.delete(recursive: true);
  }
}
