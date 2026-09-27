@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/integration_api.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

class _Store implements WorkspaceCatalogStore {
  String? value;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (writeStarted != null && !writeStarted!.isCompleted) writeStarted!.complete();
    await writeGate?.future;
    this.value = value;
  }
}

class _Catalog extends WorkspaceCatalogNotifier {
  final _Store store;
  _Catalog(this.store);
  @override
  WorkspaceCatalogState init() {
    catalog = WorkspaceCatalog(store: store, onChanged: (next) => state = next);
    return const WorkspaceCatalogState();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual child isolate parent actions main handler and publication complete without console deadlock', () async {
    // Production child RustLib.init uses FRB's environment loader, not an API mock.
    expect(Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'], isNotNull);
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-management-isolate-');
    final original = File('${temp.path}/keep.txt');
    await original.writeAsString('keep source bytes');
    final rootToken = ServicesBinding.rootIsolateToken;
    expect(rootToken, isNotNull);
    final sync = SyncState(
      rootIsolateToken: rootToken!,
      securityContext: const StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: 'fixture'),
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Test host', androidSdkInt: null),
      alias: 'Management isolate fixture',
      port: 0,
      discoveryPort: 53317,
      networkWhitelist: null,
      networkBlacklist: null,
      protocol: ProtocolType.http,
      multicastGroup: '224.0.0.167',
      discoveryTimeout: 1000,
      serverRunning: false,
      download: false,
    );
    final connector =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpServerEvent>, SendToIsolateData<IsolateTask<BaseHttpServerTask>>, InitialData>(
          task: setupHttpServerIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final store = _Store();
    final source = _Catalog(store);
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: null, httpServer: connector),
          ),
        ),
        workspaceCatalogProvider.overrideWithNotifier((_) => source),
      ],
    );
    final client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
    final server = container.notifier(serverProvider);
    try {
      container.notifier(workspaceCatalogProvider);
      final entry = await source.catalog.create(
        name: 'Closed fixture',
        slug: 'managed',
        source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: temp.path),
      );
      final started = await server.startServer(alias: 'Management isolate fixture', port: 0, https: false).timeout(const Duration(seconds: 15));
      expect(started, isNotNull);
      final publisher = container.notifier(directoryPublicationProvider);
      await publisher.synchronize();
      final key = await createIntegrationApiKeyDraft(
        name: 'Isolate test key',
        grant: jsonEncode({
          'scopes': ['workspaces.manage', 'service.read'],
          'workspaces': [entry.id],
        }),
      );
      final record = jsonDecode(await key.persistenceRecord());
      final token = (await key.takeSecret())!;
      key.dispose();
      await server.integrationApiControl(
        expectedGeneration: server.generation,
        configuration: jsonEncode({
          'revision': 1,
          'enabled': true,
          'authRequired': true,
          'keys': [record],
          'globalLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
          'keyLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 4},
          'anonymousLimits': {'perSecond': 100, 'perMinute': 6000, 'concurrent': 2},
          'anonymousGrant': {'scopes': [], 'workspaces': []},
          'allowedOrigins': [],
        }),
      );
      Future<Map<String, dynamic>> console(String operation, {Map<String, String> parameters = const {}}) async =>
          jsonDecode(
                await server
                    .integrationApiRequest(
                      expectedGeneration: server.generation,
                      request: jsonEncode({'operation': operation, 'token': token, 'parameters': parameters}),
                    )
                    .timeout(const Duration(seconds: 10)),
              )
              as Map<String, dynamic>;
      final listed = await console('listManagedWorkspaces');
      expect(listed['status'], 200);
      expect(jsonDecode(listed['body'])['workspaces'].single['enabled'], false);
      final enabled = await console('manageWorkspace', parameters: {'workspaceId': entry.id, 'action': 'enable', 'generation': '1'});
      expect(enabled['status'], 200);
      final enabledEntry = source.state.entries.single;
      expect(enabledEntry.enabled, true);
      expect(publisher.state.published, {entry.id: enabledEntry.generation});
      expect(WorkspaceCatalogCodec.decode(store.value).single.enabled, true);
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:${started!.port}/managed/'));
      final served = await request.close();
      expect(served.statusCode, 200);
      await served.drain<void>();
      store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      var acknowledged = false;
      final update =
          console(
            'manageWorkspace',
            parameters: {'workspaceId': entry.id, 'action': 'update', 'generation': '${enabledEntry.generation}', 'name': 'Updated through isolate'},
          ).then((value) {
            acknowledged = true;
            return value;
          });
      await store.writeStarted!.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(acknowledged, false);
      expect(source.state.entries.single.name, 'Closed fixture');
      store.writeGate!.complete();
      expect((await update)['status'], 200);
      expect(source.state.entries.single.name, 'Updated through isolate');
      expect(publisher.state.published[entry.id], source.state.entries.single.generation);
      store.writeGate = null;
      store.writeStarted = null;
      final stale = await console('manageWorkspace', parameters: {'workspaceId': entry.id, 'action': 'disable', 'generation': '1'});
      expect(stale['status'], 409);
      expect(source.state.entries.single.enabled, true);
      final destroyed = await console(
        'manageWorkspace',
        parameters: {'workspaceId': entry.id, 'action': 'destroy', 'generation': '${source.state.entries.single.generation}'},
      );
      expect(destroyed['status'], 200);
      expect(source.state.entries, isEmpty);
      expect(publisher.state.published, isEmpty);
      expect(await original.readAsString(), 'keep source bytes');
      expect(jsonEncode([listed, enabled, destroyed]), isNot(contains(temp.path)));
      expect(jsonEncode([listed, enabled, destroyed]), isNot(contains(token)));
    } finally {
      if (store.writeGate != null && !store.writeGate!.isCompleted) store.writeGate!.complete();
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer().timeout(const Duration(seconds: 10));
      connector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
