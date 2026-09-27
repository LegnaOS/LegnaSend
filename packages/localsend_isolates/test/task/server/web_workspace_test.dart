@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';

void main() {
  test('runtime workspace update crosses FRB without replacing port or accepted session', () async {
    final library = File('${Directory.current.path}/../../target/debug/librust_lib_localsend_app.dylib');
    if (!library.existsSync()) {
      markTestSkipped('Build the native library first');
      return;
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Test',
      version: '2.2',
      deviceModel: null,
      deviceType: null,
      fingerprint: 'test',
      pin: null,
      verifyChecksums: false,
      showToken: null,
      web: WebParams(
        mode: WebMode.duplex(
          allowUpload: false,
          files: {'file': FileDto(id: 'file', fileName: 'a.txt', size: BigInt.from(4), fileType: 'text/plain')},
        ),
        i18N: const WebI18n(
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
          textPreview: {'encoding': '编码', 'more': '加载更多'},
        ),
        pages: const WebPages(),
      ),
    );

    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_WebPrepareDownload) unawaited(server.respondPrepareDownload(sessionId: event.sessionId, accept: true));
    });
    final client = HttpClient();
    final port = await server.port();
    Future<Map<String, dynamic>> request(String path, {bool post = false}) async {
      final request = await client.openUrl(post ? 'POST' : 'GET', Uri.parse('http://127.0.0.1:$port$path'));
      final response = await request.close();
      expect(response.statusCode, 200);
      return jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    }

    try {
      final initial = await request('/api/localsend/v2/prepare-download', post: true);
      final session = initial['sessionId'];
      await server.updateWebWorkspace(
        files: {'next': FileDto(id: 'next', fileName: 'next.txt', size: BigInt.one, fileType: 'text/plain')},
        allowUpload: true,
      );
      expect(await server.port(), port);
      final status = await request('/web-status.json');
      expect(status['allowUpload'], true);
      expect(status['fileCount'], 2);
      final version = status['fileVersion'];
      expect(version, isA<String>());
      final updated = await request('/api/localsend/v2/prepare-download?sessionId=$session', post: true);
      expect(updated['sessionId'], session);
      expect((updated['files'] as Map).keys, unorderedEquals(['file', 'next']));
      await server.patchWebWorkspace(
        files: {'replacement': FileDto(id: 'replacement', fileName: 'new.txt', size: BigInt.one, fileType: 'text/plain')},
        removeFileIds: ['file'],
      );
      expect(await server.port(), port);
      final patched = await request('/api/localsend/v2/prepare-download?sessionId=$session', post: true);
      expect(patched['sessionId'], session);
      expect((patched['files'] as Map).keys, unorderedEquals(['replacement', 'next']));
      expect((await request('/web-status.json'))['fileVersion'], isNot(version));
      final stale = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/download?sessionId=$session&fileId=file'));
      final gone = await stale.close();
      expect(gone.statusCode, 410);
      await gone.drain<void>();
      await expectLater(server.patchWebWorkspace(files: {}, removeFileIds: ['file']), throwsA(anything));
      await server.updateWebWorkspace(files: {}, allowUpload: false);
      expect((await request('/web-status.json'))['allowUpload'], false);
    } finally {
      client.close(force: true);
      await server.stop();
      await listener.cancel();
    }
  });
}
