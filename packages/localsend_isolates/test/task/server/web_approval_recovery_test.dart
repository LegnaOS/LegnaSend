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
import 'package:path/path.dart' as p;

void main() {
  test('real bridge removes ten disconnected approvals and keeps later approved downloads usable', () async {
    final library = File(
      p.join(Directory.current.path, '..', '..', 'target', 'debug', switch (Platform.operatingSystem) {
        'macos' => 'librust_lib_localsend_app.dylib',
        'windows' => 'rust_lib_localsend_app.dll',
        _ => 'librust_lib_localsend_app.so',
      }),
    );
    expect(library.existsSync(), true, reason: 'Build the current native library before this regression');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final directory = await Directory.systemTemp.createTemp('legnasend-web-approval-');
    final source = await File(p.join(directory.path, 'source.txt')).writeAsString('data');
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Approval recovery',
      version: '2.2',
      deviceModel: null,
      deviceType: null,
      fingerprint: 'approval-recovery',
      pin: null,
      verifyChecksums: true,
      showToken: null,
      web: WebParams(
        mode: WebMode.duplex(
          allowUpload: false,
          files: {
            'file': FileDto(id: 'file', fileName: 'source.txt', size: BigInt.from(4), fileType: 'text/plain'),
          },
        ),
        pages: const WebPages(),
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
        ),
      ),
    );
    final events = StreamController<RsServerEvent>();
    final aborted = <String>[];
    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_WebPrepareDownloadAborted) aborted.add(event.sessionId);
      events.add(event);
    }, onError: events.addError);
    final iterator = StreamIterator(events.stream);
    Future<T> next<T extends RsServerEvent>() async {
      expect(await iterator.moveNext().timeout(const Duration(seconds: 5)), true);
      expect(iterator.current, isA<T>());
      return iterator.current as T;
    }

    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final port = await server.port();
    final base = 'http://127.0.0.1:$port/api/localsend/v2';
    final approved = <String>[];
    try {
      for (var round = 0; round < 10; round++) {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.write('POST /api/localsend/v2/prepare-download HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n');
        await socket.flush();
        final abandoned = await next<RsServerEvent_WebPrepareDownload>();
        socket.destroy();
        final ended = await next<RsServerEvent_WebPrepareDownloadAborted>();
        expect(ended.sessionId, abandoned.sessionId);
        await expectLater(server.respondPrepareDownload(sessionId: abandoned.sessionId, accept: true), throwsA(anything));

        final request = await client.postUrl(Uri.parse('$base/prepare-download'));
        final responseFuture = request.close();
        final pending = await next<RsServerEvent_WebPrepareDownload>();
        expect(pending.sessionId, isNot(abandoned.sessionId));
        await server.respondPrepareDownload(sessionId: pending.sessionId, accept: true);
        final response = await responseFuture;
        expect(response.statusCode, 200);
        final body = jsonDecode(await utf8.decodeStream(response)) as Map;
        expect(body['sessionId'], pending.sessionId);
        approved.add(pending.sessionId);
        final download = await client.getUrl(Uri.parse('$base/download?sessionId=${pending.sessionId}&fileId=file'));
        final downloadedFuture = download.close();
        final content = await next<RsServerEvent_WebFileDownload>();
        expect(content.sessionId, pending.sessionId);
        expect(
          await server.respondFileDownload(
            requestId: content.requestId,
            sessionId: content.sessionId,
            fileId: content.fileId,
            path: source.path,
          ),
          true,
        );
        final downloaded = await downloadedFuture;
        expect(downloaded.statusCode, 200);
        expect(await utf8.decodeStream(downloaded), 'data');
      }
      // Exercise the idle cleanup tick, not just the next incoming web event.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(aborted.length, 10);
      expect(aborted.toSet().intersection(approved.toSet()), isEmpty);
      for (final id in approved) {
        final request = await client.postUrl(Uri.parse('$base/prepare-download?sessionId=$id'));
        final response = await request.close();
        expect(response.statusCode, 200);
        expect((jsonDecode(await utf8.decodeStream(response)) as Map)['sessionId'], id);
      }
      expect(await server.port(), port);
    } finally {
      client.close(force: true);
      await server.stop();
      await listener.cancel();
      await iterator.cancel();
      await events.close();
      await directory.delete(recursive: true);
    }
  });
}
