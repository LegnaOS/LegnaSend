import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/api/workspace_management.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:test/test.dart';

import '../workspace/workspace_fixtures.dart';

Future<Map<String, dynamic>> execute(
  WorkspaceCatalog catalog,
  Map<String, dynamic> data, {
  Future<bool> Function()? claim,
  Future<void> Function()? publish,
}) async =>
    jsonDecode(
          await executeWorkspaceManagement(
            catalog: catalog,
            request: jsonEncode({
              'workspaces': ['*'],
              ...data,
            }),
            claim: claim ?? () async => true,
            publish: publish ?? () async {},
          ),
        )
        as Map<String, dynamic>;

Map<String, dynamic> action(String name, {int generation = 1, int id = 1}) => {
  'operation': name,
  'workspaceId': workspaceId(id),
  'generation': generation,
};
String? error(Map<String, dynamic> response) => (response['body'] as Map)['error']?['code'] as String?;

void main() {
  test('scoped list includes closed records without source, root or password verifier', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1), workspace(2)]));
    var claims = 0;
    final result = await execute(
      catalog,
      {
        'operation': 'list',
        'workspaces': [workspaceId(1)],
      },
      claim: () async {
        claims++;
        return true;
      },
    );
    expect(result['status'], 200);
    expect(claims, 1);
    final entries = result['body']['workspaces'] as List;
    expect(entries, hasLength(1));
    expect(entries.single['enabled'], false);
    expect((entries.single as Map).keys.toSet(), {
      'id',
      'name',
      'slug',
      'enabled',
      'visible',
      'allowUpload',
      'generation',
      'invalidReason',
      'passwordProtected',
    });
    expect(jsonEncode(result), isNot(contains('/workspace/')));
    expect(jsonEncode(result), isNot(contains('passwordHash')));
    expect((await execute(catalog, {'operation': 'list', 'workspaces': <String>[]}))['body']['workspaces'], isEmpty);
  });

  test('update persists one generation and keeps source route and closed state', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    var published = 0;
    final result = await execute(
      catalog,
      {...action('update'), 'name': ' Renamed ', 'visible': false, 'allowUpload': true},
      publish: () async {
        published++;
        expect(WorkspaceCatalogCodec.decode(store.raw).single.name, 'Renamed');
      },
    );
    expect(result['status'], 200);
    expect(published, 1);
    final entry = catalog.state.entries.single;
    expect(entry.generation, 2);
    expect(entry.name, 'Renamed');
    expect(entry.visible, false);
    expect(entry.allowUpload, true);
    expect(entry.source, workspace(1).source);
    expect(entry.slug, workspace(1).slug);
    expect(entry.enabled, false);
    expect(error(await execute(catalog, {...action('update'), 'name': 'Stale'})), 'stale_generation');
    expect(store.writes, 1);
  });

  test('scope denial, strict fields and invalid input never claim or write', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    var claims = 0;
    for (final input in [
      {
        ...action('disable'),
        'workspaces': [workspaceId(2)],
      },
      {...action('update'), 'root': '/secret', 'name': 'ignored'},
      {
        ...action('update'),
        'source': {'locator': '/secret'},
      },
      {...action('update'), 'slug': 'other'},
      {...action('update'), 'passwordHash': 'secret'},
      {...action('update'), 'visible': 'true'},
      {...action('update'), 'allowUpload': 1},
      {...action('update'), 'name': null},
      {...action('update'), 'name': 'bad\nname'},
      action('update'),
      {...action('disable'), 'name': 'unexpected'},
      {...action('disable'), 'generation': 1.0},
      {
        'operation': 'list',
        'workspaces': ['*', workspaceId(1)],
      },
      {
        'operation': 'list',
        'workspaces': [workspaceId(1), workspaceId(1)],
      },
    ]) {
      final result = await execute(
        catalog,
        input,
        claim: () async {
          claims++;
          return true;
        },
      );
      expect(result['status'], anyOf(400, 404));
    }
    expect(claims, 0);
    expect(store.writes, 0);
  });

  test('queued remote CAS sees preceding local UI edits and rejects stale generation', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    await catalog.initialize();
    var claims = 0;
    final local = catalog.update(workspaceId(1), name: 'Local UI');
    final remote = execute(
      catalog,
      {...action('update'), 'name': 'Remote stale'},
      claim: () async {
        claims++;
        return true;
      },
    );
    await local;
    expect(error(await remote), 'stale_generation');
    expect(claims, 0);
    expect(store.writes, 1);
    expect(catalog.state.entries.single.name, 'Local UI');
  });

  test('claim is checked at queued execution and revoked waiter performs no write', () async {
    final gate = Completer<WorkspaceProbeResult>();
    final probeStarted = Completer<void>();
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(
      store: store,
      probe: (_) {
        probeStarted.complete();
        return gate.future;
      },
    );
    await catalog.initialize();
    final local = catalog.validate(workspaceId(1));
    await probeStarted.future;
    var grant = true;
    var claims = 0;
    final remote = execute(
      catalog,
      {...action('update', generation: 2), 'name': 'Denied'},
      claim: () async {
        claims++;
        return grant;
      },
    );
    grant = false;
    gate.complete(const WorkspaceProbeResult.valid('/workspace/1'));
    await local;
    expect(error(await remote), 'management_claim_rejected');
    expect(claims, 1);
    expect(store.writes, 1);
    expect(catalog.state.entries.single.name, workspace(1).name);
  });

  test('accepted probe uses unchanged source and can finish after later revocation', () async {
    final gate = Completer<WorkspaceProbeResult>();
    final entered = Completer<void>();
    var active = true;
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([workspace(1)]),
      probe: (source) {
        expect(source, workspace(1).source);
        entered.complete();
        return gate.future;
      },
    );
    final result = execute(catalog, action('enable'), claim: () async => active);
    await entered.future;
    active = false;
    gate.complete(const WorkspaceProbeResult.valid('/workspace/1'));
    expect((await result)['status'], 200);
    expect(catalog.state.entries.single.enabled, true);
  });

  test('invalid enable remains closed with stable reason, validate never reopens it', () async {
    var valid = false;
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([workspace(1)]),
      probe: (_) async =>
          valid ? const WorkspaceProbeResult.valid('/workspace/1') : const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.missing),
    );
    final missing = await execute(catalog, action('enable'));
    expect(missing['status'], 422);
    expect(error(missing), 'workspace_invalid');
    expect(missing['body']['workspace']['enabled'], false);
    expect(missing['body']['workspace']['invalidReason'], 'missing');
    valid = true;
    final checked = await execute(catalog, action('validate', generation: 2));
    expect(checked['body']['workspace']['enabled'], false);
    expect(checked['body']['workspace']['invalidReason'], isNull);
    final enabled = await execute(catalog, action('enable', generation: 3));
    expect(enabled['body']['workspace']['enabled'], true);
    final disabled = await execute(catalog, action('disable', generation: 4));
    expect(disabled['body']['workspace']['enabled'], false);
  });

  test('corrupt catalog and failed writes preserve persisted state and suppress publication', () async {
    final broken = MemoryWorkspaceStore()..raw = '{private-corrupt-data';
    var published = 0;
    final result = await execute(
      WorkspaceCatalog(store: broken),
      action('disable'),
      publish: () async {
        published++;
      },
    );
    expect(error(result), 'catalog_malformed_failed');
    expect(broken.raw, '{private-corrupt-data');
    expect(broken.writes, 0);
    final store = MemoryWorkspaceStore([workspace(1)])..failWrite = true;
    final catalog = WorkspaceCatalog(store: store);
    final original = store.raw;
    final failed = await execute(
      catalog,
      {...action('update'), 'name': 'Unsaved'},
      publish: () async {
        published++;
      },
    );
    expect(error(failed), 'catalog_write_failed');
    expect(store.raw, original);
    expect(catalog.state.entries.single.generation, 1);
    expect(published, 0);
    expect(jsonEncode(result), isNot(contains('private-corrupt-data')));
  });

  test('publisher failure reports durable update without falsely claiming publication', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    final result = await execute(
      catalog,
      {...action('update'), 'visible': false},
      publish: () async {
        throw StateError('/private/source');
      },
    );
    expect(result['status'], 503);
    expect(error(result), 'config_saved_sync_pending');
    expect(result['body']['workspace']['generation'], 2);
    expect(WorkspaceCatalogCodec.decode(store.raw).single.visible, false);
    expect(jsonEncode(result), isNot(contains('/private/source')));
    expect(jsonEncode(result), isNot(contains('published')));
  });

  test('competing remote CAS admits only one mutation and queue remains usable', () async {
    final store = MemoryWorkspaceStore([workspace(1)]);
    final catalog = WorkspaceCatalog(store: store);
    var claims = 0;
    final outcomes = await Future.wait([
      execute(
        catalog,
        {...action('update'), 'name': 'First'},
        claim: () async {
          claims++;
          return true;
        },
      ),
      execute(
        catalog,
        {...action('update'), 'name': 'Second'},
        claim: () async {
          claims++;
          return true;
        },
      ),
    ]);
    expect(outcomes.map((result) => result['status']), [200, 409]);
    expect(claims, 1);
    expect(store.writes, 1);
    expect((await execute(catalog, action('disable', generation: 2)))['status'], 200);
  });

  test('read failure and rejected list claim return no catalog content or private diagnostic', () async {
    final broken = MemoryWorkspaceStore([workspace(1)])..failRead = true;
    final unavailable = await execute(WorkspaceCatalog(store: broken), {'operation': 'list'});
    expect(error(unavailable), 'catalog_read_failed');
    expect(broken.writes, 0);
    expect(jsonEncode(unavailable), isNot(contains('private-path')));
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1)]));
    final denied = await execute(catalog, {'operation': 'list'}, claim: () async => false);
    expect(error(denied), 'management_claim_rejected');
    expect(denied['body'].containsKey('workspaces'), false);
  });

  test('destroy publication failure reports saved removal separately from route withdrawal', () async {
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([workspace(1)]));
    final result = await execute(
      catalog,
      action('destroy'),
      publish: () async {
        throw StateError('server unavailable');
      },
    );
    expect(result['status'], 503);
    expect(result['body'], {
      'error': {'code': 'config_saved_sync_pending'},
      'id': workspaceId(1),
      'destroyed': true,
    });
    expect(catalog.state.entries, isEmpty);
  });

  test('destroy removes only catalog metadata and leaves actual source contents intact', () async {
    final root = await Directory.systemTemp.createTemp('legnasend-management-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/keep.txt');
    await file.writeAsString('original');
    final entry = workspace(1).copyWith(
      source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: root.path),
    );
    final store = MemoryWorkspaceStore([entry]);
    final catalog = WorkspaceCatalog(store: store);
    final result = await execute(catalog, action('destroy'));
    expect(result['body'], {'id': entry.id, 'destroyed': true});
    expect(catalog.state.entries, isEmpty);
    expect(await file.readAsString(), 'original');
    expect(WorkspaceCatalogCodec.decode(store.raw), isEmpty);
  });
}
