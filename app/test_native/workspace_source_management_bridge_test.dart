@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/api/workspace_management.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/util/integration_api.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';

class SourceDiskCatalogStore implements WorkspaceCatalogStore {
  final File file;
  SourceDiskCatalogStore(this.file);
  @override
  Future<String?> read() async => await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String value) async {
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  }
}

void main() {
  test('real API creates only approved closed sources, configures closed roots and hashes passwords', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-api-management-');
    final source = await Directory('${temp.path}/source').create();
    final original = File('${source.path}/keep.txt');
    await original.writeAsString('original bytes');
    final store = SourceDiskCatalogStore(File('${temp.path}/catalog.json'));
    final catalog = WorkspaceCatalog(store: store);
    final entry = await catalog.create(
      name: 'Closed fixture',
      slug: 'managed',
      source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: source.path),
    );
    final other = await catalog.create(
      name: 'Not granted',
      slug: 'other',
      source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: source.path),
    );
    final key = await createIntegrationApiKeyDraft(
      name: 'Management fixture',
      grant: jsonEncode({
        'scopes': ['workspaces.manage', 'service.read', 'requests.read'],
        'workspaces': ['*'],
      }),
    );
    final record = jsonDecode(await key.persistenceRecord());
    final token = (await key.takeSecret())!;
    key.dispose();
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Management fixture',
      version: '2.2',
      deviceModel: null,
      deviceType: null,
      fingerprint: 'fixture',
      pin: null,
      verifyChecksums: false,
      showToken: null,
      web: const WebParams(
        mode: WebMode.disabled(),
        i18N: WebI18n(
          waiting: '',
          enterPin: '',
          invalidPin: '',
          tooManyAttempts: '',
          rejected: '',
          uploadRejected: '',
          busy: '',
          files: '',
          fileName: '',
          size: '',
          dropHint: '',
        ),
        pages: WebPages(),
      ),
    );
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final failures = <Object>[];
    var revision = 0;
    Future<void> publish() async {
      await server.configureDirectoryWorkspaces(
        config: jsonEncode({
          'revision': ++revision,
          'enabled': true,
          'workspaces': [
            for (final ws in catalog.state.publishable)
              {
                'id': ws.id,
                'name': ws.name,
                'slug': ws.slug,
                'root': catalog.state.verifiedLocators[ws.id],
                'generation': ws.generation,
                'visible': ws.visible,
                'allowUpload': ws.allowUpload,
                'passwordHash': ws.passwordHash,
              },
          ],
        }),
      );
    }

    final pending = <Future<void>>[];
    final subscription = server.listen().listen((event) {
      if (event is RsServerEvent_WorkspaceManagement) {
        final task = () async {
          try {
            final response = await executeWorkspaceManagement(
              catalog: catalog,
              request: event.request,
              claim: () => server.claimWorkspaceManagement(requestId: event.requestId),
              publish: publish,
            );
            await server.respondWorkspaceManagement(requestId: event.requestId, response: response);
          } catch (error) {
            failures.add(error);
          }
        }();
        pending.add(task);
      }
    });
    final config = {
      'revision': 1,
      'enabled': true,
      'authRequired': true,
      'keys': [record],
      'globalLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
      'keyLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
      'anonymousLimits': {'perSecond': 100, 'perMinute': 6000, 'concurrent': 4},
      'anonymousGrant': {'scopes': [], 'workspaces': []},
      'allowedOrigins': [],
    };
    await server.configureIntegrationApi(config: jsonEncode(config));
    final port = await server.port();
    Future<(int, Map<String, dynamic>)> call(String action, {int? generation, String? id, Map<String, Object>? payload}) async {
      final special = ['sources', 'create', 'list'].contains(action);
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: action == 'sources'
            ? '/api/legnasend/v1/integration/approved-workspace-sources'
            : action == 'create'
            ? '/api/legnasend/v1/integration/managed-workspaces/create'
            : action == 'list'
            ? '/api/legnasend/v1/integration/managed-workspaces'
            : '/api/legnasend/v1/integration/workspaces/${id ?? entry.id}/manage',
        queryParameters: special ? null : {'action': action, 'generation': '$generation'},
      );
      final request = await client.openUrl(['sources', 'list'].contains(action) ? 'GET' : 'POST', uri);
      request.headers.set('Authorization', 'Bearer $token');
      final bytes = payload == null ? <int>[] : utf8.encode(jsonEncode(payload));
      request.contentLength = bytes.length;
      if (payload != null) request.headers.contentType = ContentType.json;
      request.add(bytes);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(body, isNot(contains(source.path)));
      expect(body, isNot(contains(token)));
      expect(body, isNot(contains('Secret-9381')));
      return (response.statusCode, jsonDecode(body) as Map<String, dynamic>);
    }

    try {
      final approved = await catalog.approveSource(
        name: 'Approved fixture',
        source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: source.path),
      );
      final alternate = await Directory('${temp.path}/alternate').create();
      final approvedOther = await catalog.approveSource(
        name: 'Another source',
        source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: alternate.path),
      );
      final (sourcesStatus, sources) = await call('sources');
      expect(sourcesStatus, 200);
      expect((sources['sources'] as List).length, 2);
      expect(sources['sources'][0].keys.toSet(), {'id', 'name', 'kind'});
      final (createStatus, created) = await call(
        'create',
        payload: {'sourceId': approved.id, 'name': 'API created', 'slug': 'api-created', 'visible': false},
      );
      expect(createStatus, 200);
      final id = created['workspace']['id'] as String;
      expect(created['workspace']['enabled'], false);
      expect(created['workspace']['generation'], 1);
      final closed = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/api-created/'))).close();
      expect(closed.statusCode, 404);
      await closed.drain<void>();
      final (configureStatus, configured) = await call(
        'configure',
        id: id,
        generation: 1,
        payload: {'sourceId': approvedOther.id, 'slug': 'changed-slug'},
      );
      expect(configureStatus, 200);
      expect(configured['workspace']['slug'], 'changed-slug');
      expect(catalog.state.entries.firstWhere((e) => e.id == id).source.locator, alternate.path);
      expect((await call('configure', id: id, generation: 1, payload: {'slug': 'stale'})).$1, 409);
      final (passwordStatus, password) = await call('password', id: id, generation: 2, payload: {'password': 'Secret-9381'});
      expect(passwordStatus, 200);
      expect(password['workspace']['passwordProtected'], true);
      final hash = catalog.state.entries.firstWhere((e) => e.id == id).passwordHash!;
      expect(hash, startsWith('pbkdf2-sha256'));
      expect(await store.file.readAsString(), isNot(contains('Secret-9381')));
      final restored = WorkspaceCatalog(store: store);
      await restored.initialize();
      expect(restored.state.entries.firstWhere((e) => e.id == id).passwordHash, hash);
      expect(restored.state.approvedSources.length, 2);
      restored.dispose();
      final (enabledStatus, enabled) = await call('enable', id: id, generation: 3);
      expect(enabledStatus, 200);
      expect(enabled['workspace']['enabled'], true);
      expect((await call('configure', id: id, generation: 4, payload: {'slug': 'not-closed'})).$1, 409);
      final (clearStatus, cleared) = await call('password', id: id, generation: 4, payload: {'clear': true});
      expect(clearStatus, 200);
      expect(cleared['workspace']['passwordProtected'], false);
      await catalog.revokeSource(approved.id);
      expect((await call('create', payload: {'sourceId': approved.id, 'name': 'Revoked', 'slug': 'revoked'})).$1, 404);
      expect(await original.readAsString(), 'original bytes');
      expect(catalog.state.entries.any((e) => e.id == other.id), true);
      final console = jsonDecode(
        await server.integrationApiRequest(
          request: jsonEncode({
            'operation': 'manageWorkspace',
            'token': token,
            'parameters': {'workspaceId': id, 'generation': '5', 'action': 'password'},
            'body': {'password': 'Secret-9381'},
          }),
        ),
      );
      expect(console['status'], 200);
      expect(console.toString(), isNot(contains('Secret-9381')));
      await Future.wait(pending);
      expect(failures, isEmpty);
    } finally {
      client.close(force: true);
      await server.stop();
      await subscription.cancel();
      await Future.wait(pending);
      catalog.dispose();
      await temp.delete(recursive: true);
    }
  });
}
