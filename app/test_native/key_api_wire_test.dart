@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/integration_api_publication_provider.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart' as native;
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

class _DiskSettings implements IntegrationApiSettingsStore {
  final File file;
  _DiskSettings(this.file);
  @override
  Future<String?> read() async => await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String value) async {
    final next = File('${file.path}.next');
    await next.writeAsString(value, flush: true);
    await next.rename(file.path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual native key lifecycle persists and publishes with one-time secret and durable receipts', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('host-api-wire-');
    await native.configureReceiveCacheRegistry(directory: temp.path);
    final userFile = await File('${temp.path}/user.txt').writeAsString('keep original');
    final security = await generateSecurityContext();
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: security,
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Wire fixture', androidSdkInt: null),
      alias: 'Wire fixture',
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
    final serverConnector =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpServerEvent>, SendToIsolateData<IsolateTask<BaseHttpServerTask>>, InitialData>(
          task: setupHttpServerIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final persistence = MockPersistenceService();
    when(persistence.getAlias()).thenReturn('Wire fixture');
    when(persistence.getSecurityContext()).thenReturn(security);
    final device = Device.empty.copyWith(alias: 'Wire fixture', fingerprint: security.certificateHash, version: '2.2');
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        integrationApiSettingsProvider.overrideWithNotifier(
          (_) => IntegrationApiSettingsNotifier(store: _DiskSettings(File('${temp.path}/api-settings.json'))),
        ),
        deviceFullInfoProvider.overrideWithBuilder((_) => device),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: null, httpServer: serverConnector),
          ),
        ),
      ],
    );
    final client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
    final server = container.notifier(serverProvider);
    try {
      final started = await server.startServer(alias: 'Wire fixture', port: 0, https: false).timeout(const Duration(seconds: 15));
      expect(started, isNotNull);
      final settings = container.notifier(integrationApiSettingsProvider);
      await settings.initialize();
      final token = await settings.createKey(
        name: 'Manager',
        grant: ApiGrant(scopes: [ApiScope.keysManage, ApiScope.service, ApiScope.requests], workspaces: ['*']),
      );
      await settings.updatePolicy(
        (policy) => policy.copyWith(enabled: true, globalLimits: const ApiLimits(1000, 60000, 16), keyLimits: const ApiLimits(1000, 60000, 8)),
      );
      await container.notifier(integrationApiPublicationProvider).synchronize();
      Future<(int, Map<String, dynamic>)> call(String path, {Object? body, bool post = false, String? credential}) async {
        final req = await client.openUrl(post ? 'POST' : 'GET', Uri.parse('http://127.0.0.1:${started!.port}/api/legnasend/v1/integration$path'));
        req.headers.set('authorization', 'Bearer ${credential ?? token}');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.add(utf8.encode(jsonEncode(body)));
        } else if (post) {
          req.contentLength = 0;
        }
        final response = await req.close();
        final result = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
        expect(jsonEncode(result), isNot(contains(temp.path)));
        expect(jsonEncode(result), isNot(contains(token)));
        return (response.statusCode, result);
      }

      final (status, snapshot) = await call('/keys');
      expect(status, 200);
      final createBody = {
        'version': snapshot['version'],
        'requestId': '11111111-1111-4111-8111-111111111111',
        'name': 'Child reader',
        'grant': {
          'scopes': ['service.read'],
          'workspaces': ['*'],
        },
        'expiresAt': null,
      };
      final (created, result) = await call('/keys/create', post: true, body: createBody);
      expect(created, 201);
      expect(result['applied'], true);
      final secret = result['secret'] as String;
      final id = result['receipt']['keyId'] as String;
      expect((await call('/status', credential: secret)).$1, 200);
      expect((await call('/keys', credential: secret)).$1, 403);
      final replay = await call('/keys/create', post: true, body: createBody);
      expect(replay.$1, 200);
      expect(replay.$2['secretAvailable'], false);
      expect(replay.$2.containsKey('secret'), false);
      final receipt = await call('/keys/requests/11111111-1111-4111-8111-111111111111');
      expect(receipt.$1, 200);
      expect(receipt.$2['receipt']['keyId'], id);
      var counter = 2;
      for (final action in ['pause', 'resume', 'revoke']) {
        final current = (await call('/keys')).$2;
        final response = await call(
          '/keys/$id/manage',
          post: true,
          body: {'version': current['version'], 'requestId': '11111111-1111-4111-8111-${(counter++).toString().padLeft(12, '0')}', 'action': action},
        );
        expect(response.$1, 200);
        expect(response.$2['applied'], true);
        expect(
          (await call('/status', credential: secret)).$1,
          action == 'resume'
              ? 200
              : action == 'pause'
              ? 403
              : 401,
        );
      }
      final disk = await File('${temp.path}/api-settings.json').readAsString();
      expect(disk, isNot(contains(secret)));
      expect(ApiSettings.decode(disk).keyReceipts, hasLength(4));
      final audit = await call('/requests');
      expect(audit.$1, 200);
      expect(jsonEncode(audit.$2), isNot(contains(secret)));
      expect(jsonEncode(audit.$2), isNot(contains('Child reader')));
      expect(await userFile.readAsString(), 'keep original');
    } finally {
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer();
      serverConnector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
