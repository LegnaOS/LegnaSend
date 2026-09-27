import 'dart:convert';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';

String workspaceId(int index) => '12345678-1234-4234-8234-${index.toString().padLeft(12, '0')}';

DirectoryWorkspace workspace(int index, {bool enabled = false, bool visible = true, WorkspaceInvalidReason? invalidReason}) => DirectoryWorkspace(
  id: workspaceId(index),
  name: '工作区 $index',
  slug: 'workspace$index',
  source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: '/workspace/$index'),
  enabled: enabled,
  visible: visible,
  generation: 1,
  invalidReason: invalidReason,
);

Future<WorkspaceProbeResult> validProbe(WorkspaceSource source) async => WorkspaceProbeResult.valid(source.locator);

class MemoryWorkspaceStore implements WorkspaceCatalogStore {
  String? raw;
  int reads = 0;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;

  MemoryWorkspaceStore([List<DirectoryWorkspace>? entries]) : raw = entries == null ? null : WorkspaceCatalogCodec.encode(entries);

  @override
  Future<String?> read() async {
    reads++;
    if (failRead) throw StateError('private-path');
    return raw;
  }

  @override
  Future<void> write(String value) async {
    writes++;
    if (failWrite) throw StateError('private-path');
    raw = value;
  }
}

final fixturePasswordHash = [
  'pbkdf2-sha256',
  '600000',
  base64Url.encode(List.filled(16, 1)).replaceAll('=', ''),
  base64Url.encode(List.filled(32, 2)).replaceAll('=', ''),
].join(r'$');
