@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  test('real FRB waits for matching publication, preserves checksum retry and rejects provider failure', () async {
    final library = File(
      p.join(Directory.current.path, '..', '..', 'target', 'debug', switch (Platform.operatingSystem) {
        'macos' => 'librust_lib_localsend_app.dylib',
        'windows' => 'rust_lib_localsend_app.dll',
        _ => 'librust_lib_localsend_app.so',
      }),
    );
    expect(library.existsSync(), true, reason: 'Build the current native bridge before this test');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final root = await Directory.systemTemp.createTemp('legnasend-cached-publication-');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Publication receiver',
      version: '2.2',
      deviceModel: null,
      deviceType: null,
      fingerprint: 'receiver',
      pin: null,
      verifyChecksums: true,
      showToken: null,
      web: const WebParams(
        mode: WebMode.disabled(),
        pages: WebPages(),
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
      ),
    );
    final base = 'http://127.0.0.1:${await server.port()}/api/localsend/v2';
    var publications = 0;
    final progress = <String, List<double>>{};
    final files = <String, (File, File)>{};
    final finished = <Future<void>>[];
    final errors = <String>[];
    final releases = <String, bool>{};
    Completer<RsServerEvent_PublishUpload>? publication;
    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_PrepareUpload) {
        finished.add(server.respondPrepareUpload(sessionId: event.sessionId, acceptedFileIds: event.files.keys.toList()));
      } else if (event is RsServerEvent_FileUpload) {
        final transaction = const Uuid().v4();
        progress[transaction] = [];
        finished.add(() async {
          try {
            final cache = await File(p.join(root.path, '$transaction.ls')).create();
            final staging = await File(p.join(root.path, '$transaction.part')).create();
            files[transaction] = (cache, staging);
            await for (final value in server.respondCachedFileUpload(
              sessionId: event.sessionId,
              fileId: event.fileId,
              transactionId: transaction,
              cachePath: cache.path,
              stagingPath: staging.path,
              fileSize: event.file.size,
            )) {
              progress[transaction]!.add(value);
            }
          } catch (_) {
            errors.add(transaction);
          }
        }());
      } else if (event is RsServerEvent_PublishUpload) {
        publications++;
        publication!.complete(event);
      } else if (event is RsServerEvent_UploadCacheReleased) {
        releases[event.transactionId] = event.published;
      }
    });
    Future<Map<String, dynamic>> prepare(List<int> bytes) async {
      final request = await client.postUrl(Uri.parse('$base/prepare-upload'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'info': {'alias': 'v2 peer', 'version': '2.2', 'fingerprint': 'sender', 'port': 53317, 'protocol': 'http'},
          'files': {
            'file': {
              'id': 'file',
              'fileName': '中文 %.bin',
              'size': bytes.length,
              'fileType': 'application/octet-stream',
              'sha256': sha256.convert(bytes).toString(),
            },
          },
        }),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      return jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
    }

    Future<int> upload(Map<String, dynamic> session, List<int> bytes) async {
      final request = await client.postUrl(
        Uri.parse('$base/upload').replace(
          queryParameters: {
            'sessionId': session['sessionId'] as String,
            'fileId': 'file',
            'token': (session['files'] as Map)['file'] as String,
          },
        ),
      );
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    Future<void> gated(Map<String, dynamic> session, List<int> bytes, {String? error}) async {
      publication = Completer<RsServerEvent_PublishUpload>();
      var httpEnded = false;
      final response = upload(session, bytes).then((status) {
        httpEnded = true;
        return status;
      });
      final event = await publication!.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(httpEnded, false);
      expect(progress[event.transactionId]!.where((value) => value >= 1), isEmpty);
      final pair = files[event.transactionId]!;
      expect(await pair.$2.readAsBytes(), bytes, reason: 'export is byte-exact before any publication acknowledgement');
      expect(await pair.$1.length(), greaterThan(bytes.length), reason: '.ls is a container, never the final file');
      expect(
        await server.respondUploadPublication(
          sessionId: event.sessionId,
          fileId: event.fileId,
          attemptId: 'stale-attempt',
          transactionId: event.transactionId,
        ),
        false,
      );
      expect(httpEnded, false);
      expect(
        await server.respondUploadPublication(
          sessionId: event.sessionId,
          fileId: event.fileId,
          attemptId: event.attemptId,
          transactionId: event.transactionId,
          error: error,
        ),
        true,
      );
      expect(
        await server.respondUploadPublication(
          sessionId: event.sessionId,
          fileId: event.fileId,
          attemptId: event.attemptId,
          transactionId: event.transactionId,
        ),
        false,
      );
      expect(await response, error == null ? 200 : 500);
      await Future.wait(List.of(finished));
      expect(progress[event.transactionId]!.contains(1), error == null);
      // Event stream and upload streams are independent; allow queued notification delivery.
      for (var i = 0; i < 20 && !releases.containsKey(event.transactionId); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(releases[event.transactionId], error == null);
    }

    try {
      final bytes = List.generate(130000, (i) => i % 251);
      await gated(await prepare(bytes), bytes);
      await gated(await prepare([]), []);
      final session = await prepare(bytes);
      final before = publications;
      final corrupted = List<int>.of(bytes)..[0] ^= 255;
      expect(await upload(session, corrupted), 422);
      await Future.wait(List.of(finished));
      expect(publications, before, reason: 'checksum mismatch cannot request publication');
      await gated(session, bytes, error: 'Provider publication failed');
      expect(errors, hasLength(2), reason: 'only the checksum and explicit publication failures');
      await gated(await prepare(bytes), bytes);
      expect(errors, hasLength(2));
      publication = Completer<RsServerEvent_PublishUpload>();
      final cancelledResponse = upload(await prepare(bytes), bytes);
      final cancelled = await publication!.future.timeout(const Duration(seconds: 10));
      await server.cancelSession(sessionId: cancelled.sessionId);
      expect(await cancelledResponse, 500);
      expect(
        await server.respondUploadPublication(
          sessionId: cancelled.sessionId,
          fileId: cancelled.fileId,
          attemptId: cancelled.attemptId,
          transactionId: cancelled.transactionId,
        ),
        false,
        reason: 'cancelled responder must not accept a late provider receipt',
      );
      await Future.wait(List.of(finished));
      expect(progress[cancelled.transactionId]!.contains(1), false);
      await gated(await prepare(bytes), bytes);
      expect(errors, hasLength(3));
    } finally {
      client.close(force: true);
      await server.stop();
      await listener.cancel();
      await root.delete(recursive: true);
    }
  });
}
