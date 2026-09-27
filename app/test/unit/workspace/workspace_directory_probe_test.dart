import 'dart:io';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('legnasend-workspace-probe-'));
  tearDown(() async => temp.delete(recursive: true));

  Future<WorkspaceProbeResult> probe(String location) =>
      probeWorkspaceDirectory(WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: location));

  test('empty directory is valid without creating a test file', () async {
    final result = await probe(temp.path);
    expect(result.isValid, true);
    expect(result.canonicalPath, await temp.resolveSymbolicLinks());
    expect(await temp.list().toList(), isEmpty);
  });

  test('missing path, regular file and relative path report typed reasons', () async {
    expect((await probe('${temp.path}/absent')).invalidReason, WorkspaceInvalidReason.missing);
    final file = await File('${temp.path}/file.txt').writeAsString('source');
    expect((await probe(file.path)).invalidReason, WorkspaceInvalidReason.notDirectory);
    expect((await probe('relative/path')).invalidReason, WorkspaceInvalidReason.notDirectory);
    expect(await file.readAsString(), 'source');
  });

  test('directory symlink resolves root without following nested links', () async {
    final root = await Directory('${temp.path}/root').create();
    final nested = await Link('${root.path}/missing').create('${temp.path}/not-found');
    final alias = await Link('${temp.path}/alias').create(root.path);
    expect((await probe(alias.path)).canonicalPath, await root.resolveSymbolicLinks());
    expect(await nested.target(), '${temp.path}/not-found');
  }, skip: Platform.isWindows ? 'Symlink privilege is platform-specific' : false);

  test('SAF and bookmarks fail closed until their native grant adapter is present', () async {
    for (final kind in [WorkspaceSourceKind.androidTree, WorkspaceSourceKind.appleBookmark]) {
      final result = await probeWorkspaceDirectory(WorkspaceSource(kind: kind, locator: temp.path, grantId: 'grant'));
      expect(result.invalidReason, WorkspaceInvalidReason.grantUnavailable);
      expect(result.canonicalPath, isNull);
    }
  });

  test('POSIX and Win32 error numbers are not interpreted interchangeably', () {
    for (final (windows, code, reason) in [
      (true, 2, WorkspaceInvalidReason.missing),
      (true, 3, WorkspaceInvalidReason.missing),
      (true, 5, WorkspaceInvalidReason.permissionDenied),
      (true, 267, WorkspaceInvalidReason.notDirectory),
      (true, 1, WorkspaceInvalidReason.ioError),
      (true, 13, WorkspaceInvalidReason.ioError),
      (true, 20, WorkspaceInvalidReason.ioError),
      (false, 2, WorkspaceInvalidReason.missing),
      (false, 1, WorkspaceInvalidReason.permissionDenied),
      (false, 13, WorkspaceInvalidReason.permissionDenied),
      (false, 20, WorkspaceInvalidReason.notDirectory),
      (false, 3, WorkspaceInvalidReason.ioError),
      (false, 5, WorkspaceInvalidReason.ioError),
    ]) {
      expect(workspacePathError(code, windows: windows), reason);
    }
    expect(workspacePathError(null, windows: true), WorkspaceInvalidReason.ioError);
    expect(workspacePathError(null, windows: false), WorkspaceInvalidReason.ioError);
  });

  test('Unicode, literal URI characters and POSIX trailing spaces stay in the real root', () async {
    final name = Platform.isWindows ? '资料 %20 # space' : '资料 %20 # space ';
    final root = await Directory('${temp.path}/$name').create();
    final result = await probe(root.path);
    expect(result.canonicalPath, await root.resolveSymbolicLinks());
    expect(result.canonicalPath, endsWith(name));
  });
}
