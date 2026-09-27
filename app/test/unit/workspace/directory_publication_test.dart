import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import 'workspace_fixtures.dart';

class TestWorkspaceCatalog extends WorkspaceCatalogNotifier {
  final MemoryWorkspaceStore store;
  final WorkspaceDirectoryProbe? probe;
  final WorkspaceWriteProbe? writeProbe;
  TestWorkspaceCatalog(this.store, {this.probe, this.writeProbe});
  @override
  WorkspaceCatalogState init() {
    catalog = WorkspaceCatalog(
      store: store,
      probe: probe ?? probeWorkspaceDirectory,
      writeProbe: writeProbe ?? probeWorkspaceWriteAccess,
      onChanged: (next) => state = next,
    );
    return const WorkspaceCatalogState();
  }
}

class DirectoryTestServer extends ServerService {
  int epoch = 9;
  bool fail = false;
  Completer<void>? gate;
  final requests = <Map<String, dynamic>>[];
  @override
  int get generation => epoch;
  @override
  ServerState? init() => const ServerState(alias: 'Fixture', port: 54321, https: false, session: null, web: null);
  @override
  Future<String> configureDirectoryWorkspaces({required int expectedGeneration, required String config}) async {
    final parsed = jsonDecode(config) as Map<String, dynamic>;
    requests.add(parsed);
    if (gate != null) await gate!.future;
    if (fail) throw StateError('fixture apply error');
    return jsonEncode({
      'revision': parsed['revision'],
      'workspaces': [
        for (final row in parsed['workspaces'] as List) {'id': row['id'], 'generation': row['generation']},
      ],
    });
  }
}

void main() {
  late Directory temp;
  late RefenaContainer container;
  late DirectoryTestServer server;
  late TestWorkspaceCatalog source;
  late DirectoryPublicationNotifier publisher;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legnasend-publication-');
    final entry = workspace(1, enabled: true).copyWith(
      source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: temp.path),
    );
    source = TestWorkspaceCatalog(MemoryWorkspaceStore([entry]));
    server = DirectoryTestServer();
    container = RefenaContainer(
      overrides: [workspaceCatalogProvider.overrideWithNotifier((_) => source), serverProvider.overrideWithNotifier((_) => server)],
    );
    container.notifier(workspaceCatalogProvider);
    await source.catalog.initialize();
    publisher = container.notifier(directoryPublicationProvider);
    await publisher.synchronize();
  });
  tearDown(() async {
    container.disposeContainer();
    await temp.delete(recursive: true);
  });

  test('publication contains only real acknowledgements and configured verified roots', () async {
    final entry = source.state.entries.single;
    expect(publisher.state.published, {entry.id: entry.generation});
    expect(server.requests.single['workspaces'][0]['root'], await temp.resolveSymbolicLinks());
    expect(server.requests.single['enabled'], true);
  });
  test('document publication keeps URI out of root and retains password and visibility', () async {
    container.disposeContainer();
    const tree = 'content://documents.example/tree/opaque%3Aroot';
    final entry = workspace(2, enabled: true, visible: false).copyWith(
      source: const WorkspaceSource(kind: WorkspaceSourceKind.androidTree, locator: tree),
      passwordHash: fixturePasswordHash,
      allowUpload: true, // Intent is published; each provider write rechecks the live grant.
    );
    source = TestWorkspaceCatalog(
      MemoryWorkspaceStore([entry]),
      probe: (_) async => const WorkspaceProbeResult.documents(tree),
      writeProbe: (_) async {},
    );
    server = DirectoryTestServer();
    container = RefenaContainer(
      overrides: [
        workspaceCatalogProvider.overrideWithNotifier((_) => source),
        serverProvider.overrideWithNotifier((_) => server),
      ],
    );
    container.notifier(workspaceCatalogProvider);
    await source.catalog.initialize();
    publisher = container.notifier(directoryPublicationProvider);
    await publisher.synchronize();
    final published = server.requests.last['workspaces'][0] as Map;
    expect(published['root'], '');
    expect(published['documentTree'], tree);
    expect(published['allowUpload'], true);
    expect(published['uploadApproval'], true);
    expect(published['passwordHash'], fixturePasswordHash);
    expect(published['visible'], false);
    expect(publisher.state.published, {entry.id: entry.generation + 1});
    await source.catalog.disable(entry.id);
    await publisher.synchronize();
    expect(server.requests.last['workspaces'], isEmpty);
    expect(publisher.state.published, isEmpty);
  });
  test('password updates are persisted and published, metadata edits retain protection, null explicitly removes it', () async {
    final id = workspaceId(1);
    await source.catalog.setPassword(id, fixturePasswordHash);
    await publisher.synchronize();
    expect(server.requests.last['workspaces'][0]['passwordHash'], fixturePasswordHash);
    await source.catalog.update(id, visible: false, name: 'changed');
    expect(source.state.entries.single.passwordHash, fixturePasswordHash);
    await source.catalog.setPassword(id, null);
    await publisher.synchronize();
    expect(source.state.entries.single.passwordHash, isNull);
    expect(server.requests.last['workspaces'][0]['passwordHash'], isNull);
  });

  test('failed close retains published identity until retry succeeds', () async {
    final before = Map.of(publisher.state.published);
    server.fail = true;
    await source.catalog.disable(workspaceId(1));
    await publisher.synchronize();
    expect(source.state.entries.single.enabled, false);
    expect(publisher.state.failed, true);
    expect(publisher.state.published, before);
    server.fail = false;
    await publisher.synchronize();
    expect(publisher.state.failed, false);
    expect(publisher.state.published, isEmpty);
  });
  test('saved rename waits for server acknowledgement before replacing published generation', () async {
    final before = Map.of(publisher.state.published);
    server.gate = Completer<void>();
    await source.catalog.update(workspaceId(1), name: 'new name');
    final syncing = publisher.synchronize();
    await Future<void>.delayed(Duration.zero);
    expect(publisher.state.busy, true);
    expect(publisher.state.published, before);
    server.gate!.complete();
    await syncing;
    expect(publisher.state.published[workspaceId(1)], source.state.entries.single.generation);
  });
  test('updates arriving during publication are drained to the latest catalog', () async {
    server.gate = Completer<void>();
    await source.catalog.update(workspaceId(1), name: 'first');
    final sync = publisher.synchronize();
    await Future<void>.delayed(Duration.zero);
    await source.catalog.update(workspaceId(1), name: 'last', visible: false);
    server.gate!.complete();
    await sync;
    expect(server.requests.last['workspaces'][0]['name'], 'last');
    expect(server.requests.last['workspaces'][0]['visible'], false);
    expect(publisher.state.published[workspaceId(1)], source.state.entries.single.generation);
  });
  test('listener generation change rejects the pending acknowledgement and reapplies', () async {
    server.gate = Completer<void>();
    await source.catalog.update(workspaceId(1), name: 'rename');
    final sync = publisher.synchronize();
    await Future<void>.delayed(Duration.zero);
    server.epoch++;
    final syncAgain = publisher.synchronize();
    server.gate!.complete();
    await Future.wait([sync, syncAgain]);
    expect(server.requests.length, greaterThanOrEqualTo(3));
    expect(publisher.state.failed, false);
    expect(publisher.state.published[workspaceId(1)], source.state.entries.single.generation);
  });
  test('upload permission requires actual server acknowledgement and leaves listener running', () async {
    final id = workspaceId(1);
    final before = publisher.state.published[id];
    expect(server.requests.last['workspaces'][0]['allowUpload'], false);
    server.fail = true;
    await source.catalog.setAllowUpload(id, true);
    await publisher.synchronize();
    expect(publisher.state.failed, true);
    expect(publisher.state.published[id], before);
    expect(server.requests.last['workspaces'][0]['allowUpload'], true);
    server.fail = false;
    await publisher.synchronize();
    expect(publisher.state.published[id], source.state.entries.single.generation);
    expect(server.epoch, 9);
    await source.catalog.setAllowUpload(id, false);
    await publisher.synchronize();
    expect(server.requests.last['workspaces'][0]['allowUpload'], false);
    expect(server.epoch, 9);
  });
}
