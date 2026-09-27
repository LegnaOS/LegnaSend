@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart' as native;
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/integration_api.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual HTTP isolate host settings and cache controls persist through acknowledged callbacks', () async {
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
      expect(await container.read(receiveCacheRetentionProvider).initialize(), true);
      final started = await server.startServer(alias: 'Wire fixture', port: 0, https: false).timeout(const Duration(seconds: 15));
      expect(started, isNotNull);
      Future<(Map<String, dynamic>, String)> key() async {
        final draft = await createIntegrationApiKeyDraft(
          name: 'Wire API',
          grant: jsonEncode({
            'scopes': ['service.read', 'settings.read', 'settings.write', 'cache.read', 'cache.clean'],
            'workspaces': ['*'],
          }),
        );
        final record = jsonDecode(await draft.persistenceRecord()) as Map<String, dynamic>;
        final token = (await draft.takeSecret())!;
        draft.dispose();
        return (record, token);
      }

      final (record, token) = await key();
      await server.integrationApiControl(
        expectedGeneration: server.generation,
        configuration: jsonEncode({
          'revision': 1,
          'enabled': true,
          'authRequired': true,
          'keys': [record],
          'globalLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
          'keyLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 8},
          'anonymousLimits': {'perSecond': 10, 'perMinute': 600, 'concurrent': 2},
          'anonymousGrant': {'scopes': [], 'workspaces': []},
          'allowedOrigins': [],
        }),
      );
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

      final (contractStatus, contract) = await call('/openapi.json?lang=zh-CN');
      expect(contractStatus, 200);
      final paths = contract['paths'] as Map;
      expect(paths['/settings']['get']['responses']['200']['content']['application/json']['schema'][r'$ref'], '#/components/schemas/HostSettings');
      expect(paths['/keys']['get']['responses']['200']['content']['application/json']['schema'][r'$ref'], '#/components/schemas/KeyList');
      expect(paths['/settings/update']['post']['responses']['409']['description'], contains('settings_busy'));
      expect(paths['/settings/update']['post']['responses']['409']['description'], isNot(contains('成功')));
      final (status, snapshot) = await call('/settings');
      expect(status, 200);
      expect(snapshot['settings']['alias'], 'Wire fixture');
      expect(snapshot['settings']['receiveCacheRetentionDays'], 0);
      expect(snapshot['receiveCacheRetention'], {'effectiveDays': 0, 'automaticCleanupPaused': false, 'busy': false, 'error': null});
      final (changed, result) = await call(
        '/settings/update',
        post: true,
        body: {'version': snapshot['version'], 'field': 'alias', 'value': 'API updated'},
      );
      expect(changed, 200);
      expect(result['settings']['alias'], 'API updated');
      expect(result['pendingRestart'], contains('alias'));
      expect(container.read(serverProvider)!.alias, 'Wire fixture');
      verify(persistence.setAlias('API updated')).called(1);
      expect((await call('/settings/update', post: true, body: {'version': snapshot['version'], 'field': 'alias', 'value': 'stale'})).$1, 409);
      expect(
        (await call('/settings/update', post: true, body: {'version': result['version'], 'field': 'destination', 'value': '/arbitrary'})).$1,
        400,
      );
      final (inspected, report) = await call('/cache');
      expect(inspected, 200);
      expect(report['unlinkedBytes'], 0);
      expect(await userFile.readAsString(), 'keep original');
      final (cleaned, cleanReport) = await call('/cache/cleanup', post: true);
      expect(cleaned, 200);
      expect(cleanReport.containsKey('entries'), true);
      expect(jsonEncode(cleanReport), isNot(contains('user.txt')));
      expect(await userFile.readAsString(), 'keep original');
      final console =
          jsonDecode(
                await server.integrationApiRequest(
                  expectedGeneration: server.generation,
                  request: jsonEncode({
                    'operation': 'updateSettings',
                    'parameters': {},
                    'token': token,
                    'body': {'version': result['version'], 'field': 'theme', 'value': 'dark'},
                  }),
                ),
              )
              as Map;
      expect(console['status'], 200);
      for (final days in [-1, 1, 7, 30, 3650, 0]) {
        final (_, before) = await call('/settings');
        final (code, updated) = await call(
          '/settings/update',
          post: true,
          body: {'version': before['version'], 'field': 'receiveCacheRetentionDays', 'value': days},
        );
        expect(code, 200);
        expect(updated['settings']['receiveCacheRetentionDays'], days);
        expect(updated['receiveCacheRetention'], {'effectiveDays': days, 'automaticCleanupPaused': false, 'busy': false, 'error': null});
        expect(updated['pendingRestart'], isNot(contains('receiveCacheRetentionDays')));
        expect(container.read(receiveCacheRetentionProvider).days, days);
        expect(parseReceiveCacheRetentionPolicy(await native.getReceiveCacheRetentionPolicy()), days);
        verify(persistence.setReceiveCacheRetentionDays(days)).called(1);
        expect(await userFile.readAsString(), 'keep original');
      }
      final (_, stable) = await call('/settings');
      for (final invalid in [true, '7', -2, 3651, 1.5]) {
        expect(
          (await call(
            '/settings/update',
            post: true,
            body: {'version': stable['version'], 'field': 'receiveCacheRetentionDays', 'value': invalid},
          )).$1,
          400,
        );
      }
      expect((await call('/settings')).$2['version'], stable['version']);
      final (_, latest) = await call('/settings');
      final (localeStatus, _) = await call('/settings/update', post: true, body: {'version': latest['version'], 'field': 'locale', 'value': 'zh-CN'});
      expect(localeStatus, 200);
      expect(LocaleSettings.currentLocale, AppLocale.zhCn);
      await LocaleSettings.setLocale(AppLocale.en);
    } finally {
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer();
      serverConnector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
