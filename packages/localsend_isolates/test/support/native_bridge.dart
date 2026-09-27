import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as path;

// Test-only isolate transport types; the app has no direct typed_isolates dependency.
export 'package:typed_isolates/typed_isolates.dart' show TypedIsolates, IsolateTask, IsolateTaskStreamResult;

/// Test-only loader; the app itself does not depend on flutter_rust_bridge.
Future<void> initializeWorkspaceNativeBridge(String repository) async {
  final name = Platform.isWindows
      ? 'rust_lib_localsend_app.dll'
      : Platform.isMacOS
      ? 'librust_lib_localsend_app.dylib'
      : 'librust_lib_localsend_app.so';
  final library = File(path.join(repository, 'target', 'debug', name));
  if (!library.existsSync()) throw StateError('Build the native bridge before this explicit integration test');
  await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
}
