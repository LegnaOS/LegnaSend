import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/api/workspace_management.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import '../workspace/workspace_fixtures.dart';

void main() {
  Future<Map<String, dynamic>> call(
    WorkspaceCatalog catalog,
    Map<String, Object?> request, {
    Future<bool> Function()? claim,
    Future<String> Function(String)? derive,
  }) async =>
      jsonDecode(
            await executeWorkspaceManagement(
              catalog: catalog,
              request: jsonEncode({
                'workspaces': ['*'],
                ...request,
              }),
              claim: claim ?? () async => true,
              publish: () async {},
              derivePassword: derive ?? (_) async => fixturePasswordHash,
            ),
          )
          as Map<String, dynamic>;
  test('local approval persists opaque source; remote creation stays closed and survives reload', () async {
    final store = MemoryWorkspaceStore();
    var id = 0;
    final catalog = WorkspaceCatalog(store: store, newId: () => workspaceId(++id), probe: validProbe);
    final approval = await catalog.approveSource(
      name: 'Approved',
      source: const WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: '/private/source'),
    );
    final sources = await call(catalog, {'operation': 'sources'});
    expect(sources['status'], 200);
    expect(sources.toString(), isNot(contains('/private/source')));
    expect(sources['body']['sources'][0]['id'], approval.id);
    final created = await call(catalog, {'operation': 'create', 'sourceId': approval.id, 'name': 'Created', 'slug': 'created', 'allowUpload': true});
    expect(created['status'], 200);
    expect(created['body']['workspace']['enabled'], false);
    expect(created['body']['workspace']['generation'], 1);
    final reloaded = WorkspaceCatalog(store: store, probe: validProbe);
    await reloaded.initialize();
    expect(reloaded.state.approvedSources.single.id, approval.id);
    expect(reloaded.state.entries.single.source.locator, '/private/source');
    expect(reloaded.state.entries.single.enabled, false);
    expect(jsonDecode(store.raw!)['version'], 4);
  });
  test('approval revoke blocks future creation without deleting existing workspace', () async {
    var id = 0;
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore(), newId: () => workspaceId(++id));
    final approval = await catalog.approveSource(name: 'Approved', source: workspace(9).source);
    final create = {'operation': 'create', 'sourceId': approval.id, 'name': 'Created', 'slug': 'created'};
    expect((await call(catalog, create))['status'], 200);
    await catalog.revokeSource(approval.id);
    expect((await call(catalog, {...create, 'slug': 'another'}))['status'], 404);
    expect(catalog.state.entries, hasLength(1));
    expect(
      (await call(catalog, {
        'operation': 'sources',
        'workspaces': [workspaceId(2)],
      }))['status'],
      404,
    );
    expect(
      (await call(catalog, {
        ...create,
        'workspaces': [workspaceId(2)],
      }))['status'],
      404,
    );
  });
  test('closed-only source and slug CAS preserves password and rejects active or stale change', () async {
    var id = 20;
    final store = MemoryWorkspaceStore([workspace(1).copyWith(passwordHash: fixturePasswordHash)]);
    final catalog = WorkspaceCatalog(store: store, newId: () => workspaceId(++id), probe: validProbe);
    final approval = await catalog.approveSource(name: 'Second', source: workspace(2).source);
    final request = {'operation': 'configure', 'workspaceId': workspaceId(1), 'generation': 1, 'sourceId': approval.id, 'slug': 'new-route'};
    expect((await call(catalog, request))['status'], 200);
    expect(catalog.state.entries.single.source, workspace(2).source);
    expect(catalog.state.entries.single.passwordHash, fixturePasswordHash);
    expect((await call(catalog, request))['status'], 409);
    await catalog.enable(workspaceId(1));
    expect(
      (await call(catalog, {...request, 'generation': catalog.state.entries.single.generation}))['body']['error']['code'],
      'workspace_must_be_closed',
    );
  });
  test('password hashes only after accepted CAS and persists verifier never plaintext then clears', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    var derives = 0;
    Future<String> derive(String value) async {
      derives++;
      expect(value, 'secret-PIN');
      return fixturePasswordHash;
    }

    final request = {'operation': 'password', 'workspaceId': workspaceId(1), 'generation': 1, 'password': 'secret-PIN'};
    expect((await call(catalog, request, claim: () async => false, derive: derive))['status'], 503);
    expect(derives, 0);
    expect((await call(catalog, request, derive: derive))['status'], 200);
    expect(derives, 1);
    expect(store.raw, isNot(contains('secret-PIN')));
    expect(WorkspaceCatalogCodec.decode(store.raw).single.passwordHash, fixturePasswordHash);
    expect((await call(catalog, {'operation': 'password', 'workspaceId': workspaceId(1), 'generation': 2, 'clear': true}))['status'], 200);
    expect(catalog.state.entries.single.passwordHash, isNull);
    expect((await call(catalog, {...request, 'generation': 3, 'clear': true}))['status'], 400);
  });
  test('arbitrary paths and malformed approval storage fail closed', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1)]));
    expect((await call(catalog, {'operation': 'configure', 'workspaceId': workspaceId(1), 'generation': 1, 'root': '/etc'}))['status'], 400);
    final encoded = jsonDecode(WorkspaceCatalogCodec.encode([workspace(1)])) as Map<String, dynamic>;
    encoded['approvedSources'] = [
      {
        'id': workspaceId(2),
        'name': 'bad',
        'source': {'kind': 'directory', 'locator': '/secret', 'unexpected': true},
      },
    ];
    expect(() => WorkspaceCatalogCodec.decode(jsonEncode(encoded)), throwsFormatException);
  });
}
