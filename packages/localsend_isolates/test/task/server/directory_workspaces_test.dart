@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as path;

void main() {
  test('real FRB catalog publishes and revokes directory routes without a port restart', () async {
    final libraryName = Platform.isWindows
        ? 'rust_lib_localsend_app.dll'
        : Platform.isMacOS
        ? 'librust_lib_localsend_app.dylib'
        : 'librust_lib_localsend_app.so';
    final library = File(path.join(Directory.current.path, '..', '..', 'target', 'debug', libraryName));
    if (!library.existsSync()) {
      markTestSkipped('Build the native library first');
      return;
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final temp = await Directory.systemTemp.createTemp('legnasend-frb-directories-');
    final file = await File('${temp.path}/hello.txt').writeAsString('bridge content');
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Fixture',
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
    final client = HttpClient();
    final port = await server.port();
    const id = '11111111-1111-4111-8111-111111111111';
    Future<HttpClientResponse> get(String path) async => (await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'))).close();
    try {
      final ack =
          jsonDecode(
                await server.configureDirectoryWorkspaces(
                  config: jsonEncode({
                    'revision': 1,
                    'enabled': true,
                    'workspaces': [
                      {'id': id, 'name': 'Bridge', 'slug': 'bridge', 'root': temp.path, 'generation': 1, 'visible': true},
                    ],
                  }),
                ),
              )
              as Map;
      expect(ack['workspaces'], [
        {'id': id, 'generation': 1},
      ]);
      final html = await get('/bridge/');
      expect(html.statusCode, 200);
      expect(await utf8.decodeStream(html), contains('/assets/directory-preview.js'));
      for (final asset in ['directory-preview.js', 'text-preview.js', 'text-reader.css']) {
        final script = await get('/assets/$asset');
        expect(script.statusCode, 200);
        await script.drain<void>();
      }
      final response = await get('/api/legnasend/v1/workspaces/$id/files?generation=1');
      final page = jsonDecode(await utf8.decodeStream(response)) as Map;
      final fileId = page['entries'][0]['id'];
      expect(await utf8.decodeStream(await get('/api/legnasend/v1/workspaces/$id/files/$fileId/content?generation=1')), 'bridge content');
      final verifier = await hashDirectoryPassword(password: 'bridge-password');
      expect(verifier, startsWith(r'pbkdf2-sha256$600000$'));
      await server.configureDirectoryWorkspaces(
        config: jsonEncode({
          'revision': 2,
          'enabled': true,
          'workspaces': [
            {'id': id, 'name': 'Bridge', 'slug': 'bridge', 'root': temp.path, 'generation': 2, 'visible': true, 'passwordHash': verifier},
          ],
        }),
      );
      final locked = await get('/api/legnasend/v1/workspaces/$id/files?generation=2');
      expect(locked.statusCode, 401);
      await locked.drain<void>();
      final unlock = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/legnasend/v1/workspaces/$id/unlock'));
      unlock.headers.contentType = ContentType.json;
      unlock.write(jsonEncode({'generation': 2, 'password': 'bridge-password'}));
      final unlocked = await unlock.close();
      expect(unlocked.statusCode, 200);
      final cookie = unlocked.cookies.single;
      expect(cookie.httpOnly, true);
      await unlocked.drain<void>();
      final authenticated = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/legnasend/v1/workspaces/$id/files/$fileId/content?generation=2'),
      );
      authenticated.cookies.add(cookie);
      expect(await utf8.decodeStream(await authenticated.close()), 'bridge content');
      final previewUri = Uri.parse('http://127.0.0.1:$port/api/legnasend/v1/workspaces/$id/files/$fileId/content?generation=2&preview=1');
      final head = await client.headUrl(previewUri);
      head.cookies.add(cookie);
      final metadata = await head.close();
      expect(metadata.statusCode, 200);
      expect(metadata.headers.contentType?.mimeType, 'text/plain');
      final version = metadata.headers.value(HttpHeaders.etagHeader)!;
      await metadata.drain<void>();
      final range = await client.getUrl(previewUri.replace(queryParameters: {...previewUri.queryParameters, 'version': version}));
      range.cookies.add(cookie);
      range.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
      final inline = await range.close();
      expect(inline.statusCode, 206);
      expect(inline.headers.value('content-disposition'), startsWith('inline;'));
      expect(await utf8.decodeStream(inline), 'bridge');
      Future<void> uploadPermission(bool allow, int generation) async {
        await server.configureDirectoryWorkspaces(
          config: jsonEncode({
            'revision': generation,
            'enabled': true,
            'workspaces': [
              {
                'id': id,
                'name': 'Bridge',
                'slug': 'bridge',
                'root': temp.path,
                'generation': generation,
                'visible': true,
                'passwordHash': verifier,
                'allowUpload': allow,
              },
            ],
          }),
        );
      }

      Future<HttpClientResponse> upload(int generation, String name) async {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/legnasend/v1/workspaces/$id/upload?generation=$generation&path=$name'),
        );
        request.cookies.add(cookie);
        request.headers.set('X-LegnaSend-Upload', '1');
        request.headers.contentType = ContentType.binary;
        request.contentLength = 3;
        request.add([0, 128, 255]);
        return request.close();
      }

      await uploadPermission(true, 3);
      final saved = await upload(3, 'uploaded.bin');
      expect(saved.statusCode, 201);
      final receipt = jsonDecode(await utf8.decodeStream(saved)) as Map;
      expect(receipt['size'], 3);
      expect(receipt['path'], 'uploaded.bin');
      expect(await File('${temp.path}/uploaded.bin').readAsBytes(), [0, 128, 255]);
      await uploadPermission(false, 4);
      final denied = await upload(4, 'denied.bin');
      expect(denied.statusCode, 403);
      await denied.drain<void>();
      expect(await File('${temp.path}/denied.bin').exists(), false);
      expect(await server.port(), port);
      await server.configureDirectoryWorkspaces(config: jsonEncode({'revision': 5, 'enabled': true, 'workspaces': []}));
      final gone = await get('/bridge/');
      expect(gone.statusCode, 404);
      await gone.drain<void>();
      expect(await server.port(), port);
      expect(await file.readAsString(), 'bridge content');
    } finally {
      client.close(force: true);
      await server.stop();
      await events.cancel();
      await temp.delete(recursive: true);
    }
  });
}
