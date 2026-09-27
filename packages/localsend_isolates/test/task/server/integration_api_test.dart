@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/integration_api.dart';
import 'package:path/path.dart' as path;

void main() {
  test('real opaque key bridge applies scoped policy and revokes HTTP access without rebinding', () async {
    final libraryName = Platform.isWindows
        ? 'rust_lib_localsend_app.dll'
        : Platform.isMacOS
        ? 'librust_lib_localsend_app.dylib'
        : 'librust_lib_localsend_app.so';
    final library = File(path.join(Directory.current.path, '..', '..', 'target', 'debug', libraryName));
    expect(library.existsSync(), true, reason: 'Build the native library before running the integration test');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final grant = jsonEncode({
      'scopes': ['service.read', 'files.upload'],
      'workspaces': ['11111111-1111-4111-8111-111111111111'],
    });
    final draft = await createIntegrationApiKeyDraft(name: 'Bridge key', grant: grant);
    final record = jsonDecode(await draft.persistenceRecord());
    final secret = await draft.takeSecret();
    expect(secret, isNotNull);
    expect(await draft.takeSecret(), isNull);
    expect(draft.toString(), isNot(contains(secret!)));
    draft.dispose();
    final config = <String, dynamic>{
      'revision': 1,
      'enabled': true,
      'authRequired': true,
      'globalLimits': {'perSecond': 30, 'perMinute': 600, 'concurrent': 16},
      'keyLimits': {'perSecond': 30, 'perMinute': 300, 'concurrent': 4},
      'anonymousLimits': {'perSecond': 5, 'perMinute': 60, 'concurrent': 2},
      'anonymousGrant': {
        'scopes': ['service.read'],
        'workspaces': [],
      },
      'allowedOrigins': [],
      'keys': [record],
    };
    await validateIntegrationApiSettings(jsonEncode(config));
    await expectLater(validateIntegrationApiSettings('SECRET'), throwsA(anything));
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'API bridge',
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
    final events = server.listen().listen((_) {});
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final port = await server.port();
    Future<HttpClientResponse> get(String route, {bool key = true}) async {
      final request = await client.getUrl(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: route));
      if (key) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      return request.close();
    }

    const endpoint = '/api/legnasend/v1/integration/status';
    try {
      final ack = jsonDecode(await server.configureIntegrationApi(config: jsonEncode(config)));
      expect(ack, {'revision': 1, 'enabled': true, 'keys': 1});
      final snapshot = await server.integrationApiSnapshot();
      expect(snapshot, isNot(contains(secret)));
      expect(snapshot, isNot(contains(record['verifier'])));
      final response = await get(endpoint);
      expect(response.statusCode, 200);
      expect(jsonDecode(await utf8.decodeStream(response))['principal'], record['id']);
      final console = jsonDecode(await server.integrationApiRequest(request: jsonEncode({'operation': 'getStatus', 'token': secret})));
      expect(console['status'], 200);
      expect(jsonDecode(console['body'])['principal'], record['id']);
      expect(console.toString(), isNot(contains(secret)));
      final denied = jsonDecode(await server.integrationApiRequest(request: jsonEncode({'operation': 'getStatus'})));
      expect(denied['status'], 401);
      final root = await Directory.systemTemp.createTemp('legnasend-api-share-');
      try {
        await server.configureDirectoryWorkspaces(
          config: jsonEncode({
            'revision': 1,
            'enabled': true,
            'workspaces': [
              {
                'id': '11111111-1111-4111-8111-111111111111',
                'name': 'Bridge directory',
                'slug': 'bridge-directory',
                'root': root.path,
                'generation': 1,
                'visible': true,
              },
            ],
          }),
        );
        final source = await File('${root.path}/console-source.bin').writeAsBytes([0, 128, 255, 13, 10]);
        final uploaded =
            jsonDecode(
                  await server.integrationApiRequest(
                    request: jsonEncode({
                      'operation': 'uploadFile',
                      'token': secret,
                      'parameters': {'workspaceId': '11111111-1111-4111-8111-111111111111', 'generation': '1', 'path': 'folder/uploaded.bin'},
                      'uploadPath': source.path,
                      'uploadSize': 5,
                    }),
                  ),
                )
                as Map;
        expect(uploaded['status'], 201);
        expect(await File('${root.path}/folder/uploaded.bin').readAsBytes(), [0, 128, 255, 13, 10]);
        expect(uploaded.toString(), isNot(contains(source.path)));
        expect(uploaded.toString(), isNot(contains(secret)));
        for (final enabled in [true, false, true, false]) {
          await server.setWebWorkspace(enabled: enabled, files: {}, allowUpload: false);
          final share = await get('/share', key: false);
          expect(share.statusCode, enabled ? 200 : 403);
          await share.drain<void>();
          final directory = await get('/bridge-directory/', key: false);
          expect(directory.statusCode, 200);
          await directory.drain<void>();
          final stillActive = await get(endpoint);
          expect(stillActive.statusCode, 200);
          await stillActive.drain<void>();
          expect(await server.port(), port);
        }
      } finally {
        await root.delete(recursive: true);
      }
      config['keys'] = [];
      config['revision'] = 2;
      await server.configureIntegrationApi(config: jsonEncode(config));
      final revoked = await get(endpoint);
      expect(revoked.statusCode, 401);
      await revoked.drain<void>();
      config['enabled'] = false;
      config['revision'] = 3;
      await server.configureIntegrationApi(config: jsonEncode(config));
      final disabled = await get(endpoint);
      expect(disabled.statusCode, 404);
      await disabled.drain<void>();
      final native = await get('/api/localsend/v2/info', key: false);
      expect(native.statusCode, 200);
      await native.drain<void>();
      expect(await server.port(), port);
    } finally {
      client.close(force: true);
      await server.stop();
      await events.cancel();
    }
  });
}
