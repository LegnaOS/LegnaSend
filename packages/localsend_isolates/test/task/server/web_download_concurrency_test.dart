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
  test('same-file requests resolve out of order without replacing one another', () async {
    final base = '${Directory.current.path}/../../target/debug';
    final libraries = [
      File('$base/librust_lib_localsend_app.dylib'),
      File('$base/librust_lib_localsend_app.so'),
      File('$base/rust_lib_localsend_app.dll'),
    ];
    final library = libraries.where((f) => f.existsSync()).firstOrNull;
    if (library == null) {
      markTestSkipped('Build the native library first');
      return;
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final directory = await Directory.systemTemp.createTemp('legnasend-download-requests');
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
    final events = StreamController<RsServerEvent_WebFileDownload>();
    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_WebPrepareDownload) unawaited(server.respondPrepareDownload(sessionId: event.sessionId, accept: true));
      if (event is RsServerEvent_WebFileDownload) events.add(event);
    });
    final iterator = StreamIterator(events.stream);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..maxConnectionsPerHost = 8;
    final port = await server.port();
    final baseUrl = 'http://127.0.0.1:$port/api/localsend/v2';
    try {
      final translations = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/i18n.json'))).close();
      final i18n = jsonDecode(await utf8.decodeStream(translations)) as Map;
      expect(i18n['textPreview'], {'encoding': '编码', 'more': '加载更多'});
      final prepare = await (await client.postUrl(Uri.parse('$baseUrl/prepare-download'))).close();
      expect(prepare.statusCode, 200);
      final sessionId = (jsonDecode(await utf8.decodeStream(prepare)) as Map)['sessionId'] as String;
      final pending = <RsServerEvent_WebFileDownload>[];
      final downloads = <Future<(int, String)>>[];
      for (var i = 0; i < 4; i++) {
        final request = await client.getUrl(Uri.parse('$baseUrl/download?sessionId=$sessionId&fileId=file'));
        request.headers.set('Range', 'bytes=1-2');
        downloads.add(request.close().then((response) async => (response.statusCode, await utf8.decodeStream(response))));
        expect(await iterator.moveNext().timeout(const Duration(seconds: 5)), isTrue);
        pending.add(iterator.current);
      }
      expect(pending.map((e) => e.requestId).toSet().length, 4);
      for (var i = 3; i >= 0; i--) {
        final event = pending[i];
        final file = await File('${directory.path}/$i').writeAsString('$i$i$i$i');
        expect(await server.respondFileDownload(requestId: event.requestId, sessionId: 'wrong', fileId: event.fileId, path: file.path), isFalse);
        if (i == 1) {
          await server.failFileDownload(requestId: event.requestId, sessionId: event.sessionId, fileId: event.fileId);
        } else {
          expect(
            await server.respondFileDownload(requestId: event.requestId, sessionId: event.sessionId, fileId: event.fileId, path: file.path),
            isTrue,
          );
        }
        expect(
          await server.respondFileDownload(requestId: event.requestId, sessionId: event.sessionId, fileId: event.fileId, path: file.path),
          isFalse,
        );
      }
      final results = await Future.wait(downloads).timeout(const Duration(seconds: 10));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].$1, i == 1 ? 500 : 206);
        if (i != 1) expect(results[i].$2, '$i$i');
      }
      // Revocation crosses the real bridge and releases a selected pending source,
      // without replacing the listener or another file's pending request.
      await server.updateWebWorkspace(
        files: {'keep': FileDto(id: 'keep', fileName: 'keep.txt', size: BigInt.from(4), fileType: 'text/plain')},
        allowUpload: true,
      );
      final removedRequest = await client.getUrl(Uri.parse('$baseUrl/download?sessionId=$sessionId&fileId=file'));
      final removedResponse = removedRequest.close();
      expect(await iterator.moveNext().timeout(const Duration(seconds: 5)), true);
      final removedEvent = iterator.current;
      final keptRequest = await client.getUrl(Uri.parse('$baseUrl/download?sessionId=$sessionId&fileId=keep'));
      final keptResponse = keptRequest.close();
      expect(await iterator.moveNext().timeout(const Duration(seconds: 5)), true);
      final keptEvent = iterator.current;
      await server.patchWebWorkspace(files: {}, removeFileIds: ['file']);
      final removed = await removedResponse.timeout(const Duration(seconds: 5));
      expect(removed.statusCode, 410);
      await removed.drain<void>();
      final source = await File('${directory.path}/kept').writeAsString('kept');
      expect(await server.respondFileDownload(requestId: removedEvent.requestId, sessionId: sessionId, fileId: 'file', path: source.path), false);
      expect(await server.respondFileDownload(requestId: keptEvent.requestId, sessionId: sessionId, fileId: 'keep', path: source.path), true);
      final kept = await keptResponse.timeout(const Duration(seconds: 5));
      expect(kept.statusCode, 200);
      expect(await utf8.decodeStream(kept), 'kept');
      expect(await server.port(), port);
    } finally {
      client.close(force: true);
      await server.stop();
      await listener.cancel().timeout(const Duration(seconds: 5));
      await iterator.cancel();
      await events.close();
      await directory.delete(recursive: true);
    }
  });
}
