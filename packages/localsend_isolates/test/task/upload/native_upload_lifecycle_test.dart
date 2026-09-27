@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as crypto;
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

void main() {
  test('native exact-size upload handles status errors, cancellation, next send and source failure', () async {
    final library = p.join(
      Directory.current.path,
      '..',
      '..',
      'target',
      'debug',
      Platform.isWindows
          ? 'rust_lib_localsend_app.dll'
          : Platform.isMacOS
          ? 'librust_lib_localsend_app.dylib'
          : 'librust_lib_localsend_app.so',
    );
    expect(File(library).existsSync(), true);
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    final identity = await crypto.generateSecurityContext();
    final client = createClient(
      privateKey: identity.privateKey,
      cert: identity.certificate,
      version: LsHttpClientVersion.v2,
      expectedFingerprint: identity.certificateHash,
    );
    final root = await Directory.systemTemp.createTemp('legnasend-upload-lifecycle-');
    final file = File(p.join(root.path, 'source.bin'));
    final bytes = List<int>.generate(4096, (i) => i & 255);
    await file.writeAsBytes(bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    final handlers = <Future<void>>[];
    final listener = server.listen((request) {
      handlers.add(() async {
        requests++;
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/localsend/v2/upload');
        expect(request.uri.queryParameters.keys.toSet(), {'sessionId', 'fileId', 'token'});
        expect(request.contentLength, bytes.length);
        expect(await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk)), bytes);
        switch (request.uri.queryParameters['token']) {
          case 'reject':
            request.response.statusCode = 403;
          case 'checksum':
            request.response.statusCode = 422;
          case 'wait':
            arrived.complete();
            await release.future;
        }
        try {
          await request.response.close();
        } catch (_) {
          /* Sender may have cancelled. */
        }
      }());
    });
    Future<List<RsUploadEvent>> send(String token, {RsCancellationToken? cancel, String? path}) => client
        .upload(
          protocol: ProtocolType.http,
          ip: '127.0.0.1',
          port: server.port,
          sessionId: 'session',
          fileId: 'file',
          token: token,
          path: path ?? file.path,
          contentLength: BigInt.from(bytes.length),
          cancelToken: cancel ?? createCancellationToken(),
        )
        .toList()
        .timeout(const Duration(seconds: 5));
    try {
      for (final (token, status) in [('reject', 403), ('checksum', 422)]) {
        final events = await send(token);
        expect(events.last, isA<RsUploadEvent_Failed>());
        expect((events.last as RsUploadEvent_Failed).error, isA<RsHttpClientError_StatusCode>().having((error) => error.status, 'status', status));
        expect(events.whereType<RsUploadEvent_Failed>(), hasLength(1));
      }
      final cancel = createCancellationToken();
      final waiting = send('wait', cancel: cancel);
      await arrived.future.timeout(const Duration(seconds: 5));
      cancel.cancel();
      final cancelled = await waiting;
      expect(cancelled.last, isA<RsUploadEvent_Failed>());
      release.complete();
      final next = await send('ok');
      expect(next.whereType<RsUploadEvent_Failed>(), isEmpty);
      expect(next.whereType<RsUploadEvent_Progress>().last.progress, 1);
      final missing = await send('ok', path: p.join(root.path, 'missing'));
      expect((missing.single as RsUploadEvent_Failed).error, isA<RsHttpClientError_Io>());
      expect(requests, 4, reason: 'Unreadable sources fail before sending an HTTP request');
    } finally {
      if (!release.isCompleted) release.complete();
      client.dispose();
      await server.close(force: true);
      await listener.cancel();
      await Future.wait(handlers);
      await root.delete(recursive: true);
    }
  });
}
