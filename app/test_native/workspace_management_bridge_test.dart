@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/api/api_history_export.dart';
import 'package:localsend_app/util/api/workspace_management.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/util/integration_api.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';

class DiskCatalogStore implements WorkspaceCatalogStore {
  final File file;
  DiskCatalogStore(this.file);
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
  test('real management event persists, publishes, rejects stale writes and preserves source files', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-api-management-');
    final source = await Directory('${temp.path}/source').create();
    final original = File('${source.path}/keep.txt');
    await original.writeAsString('original bytes');
    final store = DiskCatalogStore(File('${temp.path}/catalog.json'));
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
        'workspaces': [entry.id],
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
    Completer<RsServerEvent_WorkspaceManagement>? holdNext;
    final subscription = server.listen().listen((event) {
      if (event is RsServerEvent_WorkspaceManagement) {
        final task = () async {
          try {
            final hold = holdNext;
            if (hold != null) {
              holdNext = null;
              expect(await server.claimWorkspaceManagement(requestId: event.requestId), true);
              hold.complete(event);
              return;
            }
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
    Future<(int, Map<String, dynamic>)> call(String action, {int? generation, Map<String, String> fields = const {}, String? id}) async {
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: action == 'list'
            ? '/api/legnasend/v1/integration/managed-workspaces'
            : '/api/legnasend/v1/integration/workspaces/${id ?? entry.id}/manage',
        queryParameters: action == 'list' ? null : {'action': action, 'generation': '$generation', ...fields},
      );
      final request = await client.openUrl(action == 'list' ? 'GET' : 'POST', uri);
      request.headers.set('Authorization', 'Bearer $token');
      request.contentLength = 0;
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(body, isNot(contains(source.path)));
      expect(body, isNot(contains(token)));
      return (response.statusCode, jsonDecode(body) as Map<String, dynamic>);
    }

    try {
      final (listStatus, list) = await call('list');
      expect(listStatus, 200);
      expect((list['workspaces'] as List).length, 1);
      expect(list['workspaces'][0]['enabled'], false);
      final (enabledStatus, enabled) = await call('enable', generation: entry.generation);
      expect(enabledStatus, 200);
      expect(enabled['workspace']['enabled'], true);
      final generation = enabled['workspace']['generation'] as int;
      final page = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/managed/'))).close();
      expect(page.statusCode, 200);
      await page.drain<void>();
      final (staleStatus, _) = await call('disable', generation: entry.generation);
      expect(staleStatus, 409);
      final (changedStatus, changed) = await call(
        'update',
        generation: generation,
        fields: {'name': 'Renamed', 'visible': 'false', 'allowUpload': 'true'},
      );
      expect(changedStatus, 200);
      expect(changed['workspace']['name'], 'Renamed');
      expect(changed['workspace']['visible'], false);
      expect(changed['workspace']['allowUpload'], true);
      final persisted = jsonDecode(await store.file.readAsString()).toString();
      expect(persisted, contains('Renamed'));
      final (closedStatus, closed) = await call('disable', generation: changed['workspace']['generation']);
      expect(closedStatus, 200);
      final closedPage = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/managed/'))).close();
      expect(closedPage.statusCode, 404);
      await closedPage.drain<void>();
      final restored = WorkspaceCatalog(store: store);
      await restored.initialize();
      final restoredEntry = restored.state.entries.firstWhere((e) => e.id == entry.id);
      expect(restoredEntry.enabled, false);
      expect(restoredEntry.name, 'Renamed');
      expect(restoredEntry.visible, false);
      expect(restoredEntry.allowUpload, true);
      restored.dispose();
      final (otherStatus, _) = await call('destroy', id: other.id, generation: other.generation);
      expect(otherStatus, 403);
      final (destroyStatus, destroyed) = await call('destroy', generation: closed['workspace']['generation']);
      expect(destroyStatus, 200);
      expect(destroyed['destroyed'], true);
      expect(await original.readAsString(), 'original bytes');
      expect(catalog.state.entries.single.id, other.id);
      // Real native console reaches the same listener and host event handler.
      final result = jsonDecode(
        await server.integrationApiRequest(request: jsonEncode({'operation': 'listManagedWorkspaces', 'token': token, 'parameters': {}})),
      );
      expect(result['status'], 200);
      // Export the actual listener audit through the native console and write
      // original JSON/CSV bytes to disk, not a substitute history fixture.
      final history = await collectApiHistory((after) async {
        final response =
            jsonDecode(
                  await server.integrationApiRequest(
                    request: jsonEncode({
                      'operation': 'listRequests',
                      'token': token,
                      'parameters': {'after': after.toString(), 'limit': '100'},
                    }),
                  ),
                )
                as Map<String, dynamic>;
        expect(response['status'], 200);
        expect(response['truncated'], isNot(true));
        return jsonDecode(response['body'] as String) as Map<String, dynamic>;
      });
      expect(history.entries, isNotEmpty);
      expect(history.entries.any((row) => row['operation'] == 'manageWorkspace'), true);
      for (final csv in [false, true]) {
        final file = File('${temp.path}/history.${csv ? 'csv' : 'json'}');
        final bytes = history.encode(csv: csv);
        await file.writeAsBytes(bytes, flush: true);
        expect(await file.readAsBytes(), bytes);
        final content = utf8.decode(bytes);
        expect(content, isNot(contains(token)));
        expect(content, isNot(contains(source.path)));
      }
      // A claimed operation may still be saving after HTTP stops waiting. The
      // periodic FRB cleanup must retain its key/global quota until host receipt.
      final held = Completer<RsServerEvent_WorkspaceManagement>();
      holdNext = held;
      final timeoutResponse = call('list');
      final heldEvent = await held.future;
      final (timeoutStatus, timeoutBody) = await timeoutResponse;
      expect(timeoutStatus, 504);
      expect(timeoutBody['error']['code'], 'outcome_unknown');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(jsonDecode(await server.integrationApiSnapshot())['activeResponses'], 1);
      await expectLater(
        server.respondWorkspaceManagement(
          requestId: heldEvent.requestId,
          response: jsonEncode({
            'status': 200,
            'body': {'workspaces': []},
          }),
        ),
        throwsA(anything),
      );
      expect(jsonDecode(await server.integrationApiSnapshot())['activeResponses'], 0);
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
