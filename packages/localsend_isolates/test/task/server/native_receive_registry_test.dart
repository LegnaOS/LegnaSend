@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

void main() {
  test('real bridge registers path writes, skips active cleanup and retires cancelled/completed attempts', () async {
    final library = File(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'target',
        'debug',
        Platform.isMacOS
            ? 'librust_lib_localsend_app.dylib'
            : Platform.isWindows
            ? 'rust_lib_localsend_app.dll'
            : 'librust_lib_localsend_app.so',
      ),
    );
    expect(library.existsSync(), true, reason: 'Build the current native bridge before running this test');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final root = await Directory.systemTemp.createTemp('legnasend-receive-registry-');
    final destination = await Directory(p.join(root.path, 'Downloads 中文 %')).create();
    final registry = Directory(p.join(root.path, 'registry'));
    expect(jsonDecode(await getReceiveCacheRetentionPolicy()), {'mode': 'immediate', 'days': null});
    expect(jsonDecode(await configureReceiveCacheRetentionPolicy(mode: 'days', days: 7)), {'mode': 'days', 'days': 7});
    await expectLater(configureReceiveCacheRetentionPolicy(mode: 'days', days: 0), throwsA(anything));
    expect(jsonDecode(await getReceiveCacheRetentionPolicy()), {'mode': 'days', 'days': 7});
    await configureReceiveCacheRetentionPolicy(mode: 'manual', days: null);
    await configureReceiveCacheRegistry(directory: registry.path);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Registry receiver',
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
    final writing = Completer<void>();
    final finished = <Future<void>>[];
    final failures = <Object>[];
    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_PrepareUpload) {
        unawaited(server.respondPrepareUpload(sessionId: event.sessionId, acceptedFileIds: event.files.keys.toList()));
      } else if (event is RsServerEvent_FileUpload) {
        finished.add(() async {
          try {
            await for (final progress in server.respondFileUpload(
              sessionId: event.sessionId,
              fileId: event.fileId,
              path: p.join(destination.path, event.file.fileName),
              fileSize: event.file.size,
            )) {
              if (progress > 0 && !writing.isCompleted) writing.complete();
            }
          } catch (error) {
            failures.add(error);
          }
        }());
      }
    });
    Future<Map<String, dynamic>> prepare(int size) async {
      final request = await client.postUrl(Uri.parse('$base/prepare-upload'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'info': {'alias': 'v2 sender', 'version': '2.2', 'fingerprint': 'sender', 'port': 53317, 'protocol': 'http'},
          'files': {
            'out': {'id': 'out', 'fileName': 'original.bin', 'size': size, 'fileType': 'application/octet-stream'},
          },
        }),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      return jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
    }

    Future<HttpClientRequest> upload(Map<String, dynamic> session) => client.postUrl(
      Uri.parse('$base/upload').replace(
        queryParameters: {
          'sessionId': session['sessionId'] as String,
          'fileId': 'out',
          'token': (session['files'] as Map)['out'] as String,
        },
      ),
    );
    try {
      final session = await prepare(4 * 1024 * 1024);
      final request = await upload(session);
      request.bufferOutput = false;
      request.contentLength = 4 * 1024 * 1024;
      request.add(Uint8List(1024 * 1024));
      await request.flush();
      await writing.future.timeout(const Duration(seconds: 5));
      final records = await registry.list().where((entry) => entry is File).toList();
      expect(records, hasLength(1));
      final record = await File(records.single.path).readAsString();
      expect(record, isNot(contains((session['files'] as Map)['out'] as String)));
      final inspection = jsonDecode(await inspectReceiveCacheRegistry(limit: 100)) as Map;
      expect(inspection['inspection'], true);
      expect(inspection['active'], 1);
      expect(inspection['removedFiles'], 0);
      expect(inspection['removedRecords'], 0);
      final inspectedEntries = inspection['entries'] as List;
      expect(inspectedEntries, hasLength(1));
      expect(inspectedEntries.single['disposition'], 'active');
      expect(inspectedEntries.single['reason'], 'active_registration');
      expect(inspectedEntries.single['id'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await registry.list().length, 1);
      expect(await File(records.single.path).readAsString(), record);
      final overridePreview = jsonDecode(await inspectReceiveCacheRegistryNow(limit: 100)) as Map;
      expect(overridePreview['inspection'], true);
      expect(overridePreview['active'], 1);
      final overrideCleanup = jsonDecode(await cleanupReceiveCacheRegistryNow(limit: 100)) as Map;
      expect(overrideCleanup['active'], 1);
      expect(overrideCleanup['removedFiles'], 0);
      final active = jsonDecode(await cleanupReceiveCacheRegistry(limit: 100)) as Map;
      expect(active['active'], 1);
      expect(active['removedFiles'], 0);
      expect(File(p.join(destination.path, 'original.bin')).existsSync(), false);
      await server.cancelSession(sessionId: session['sessionId'] as String);
      await Future.wait(finished).timeout(const Duration(seconds: 5));
      request.abort();
      expect(failures, hasLength(1));
      expect(await registry.list().length, 0);
      expect(await destination.list().length, 0, reason: 'Manual crash-residue retention does not retain a normal cancellation');
      expect(jsonDecode(await getReceiveCacheRetentionPolicy()), {'mode': 'manual', 'days': null});
      final next = await prepare(4);
      final complete = await upload(next);
      complete.add([1, 2, 3, 4]);
      final response = await complete.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      await Future.wait(finished);
      expect(await File(p.join(destination.path, 'original.bin')).readAsBytes(), [1, 2, 3, 4]);
      expect(await registry.list().length, 0);
      expect(await destination.list().length, 1);
      final report = jsonDecode(await cleanupReceiveCacheRegistry(limit: 100)) as Map;
      expect(report['removedFiles'], 0);
      expect(report['failed'], 0);
    } finally {
      await configureReceiveCacheRetentionPolicy(mode: 'immediate', days: null);
      client.close(force: true);
      await server.stop();
      await listener.cancel();
      await root.delete(recursive: true);
    }
  });
}
