@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';
import 'package:path/path.dart' as p;

void main() {
  test('real HTTP bridge reserves concurrent duplicate names and reuses the same target on checksum retry', () async {
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
    final root = await Directory.systemTemp.createTemp('legnasend-receive-names-');
    final destination = await Directory(p.join(root.path, 'Downloads 中文 %')).create();
    final registry = Directory(p.join(root.path, 'registry'));
    await configureReceiveCacheRegistry(directory: registry.path);
    const fileCount = 32;
    const incomingName = 'folder 中文/duplicate %.bin';
    final original = File(p.join(destination.path, incomingName));
    await original.parent.create(recursive: true);
    await original.writeAsBytes([9, 8, 7, 6]);
    final bytes = <String, Uint8List>{
      for (var index = 0; index < fileCount; index++)
        'file-$index': Uint8List.fromList(List.generate(4096 + index, (offset) => (offset * 31 + index) % 256)),
    };
    final client = HttpClient()..maxConnectionsPerHost = fileCount;
    client.findProxy = (_) => 'DIRECT';
    final server = await startServer(
      port: 0,
      tls: null,
      alias: 'Concurrent names receiver',
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
    final sessionScopeReceivePathReservations = ReceivePathReservations();
    final createdDirectories = <String>{};
    final targets = <String, FileSaveTarget>{};
    final attempts = <String, List<String>>{};
    final finished = <Future<void>>[];
    final failures = <(String, Object)>[];
    final allTargetsReserved = Completer<void>();
    final listener = server.listen().listen((event) {
      if (event is RsServerEvent_PrepareUpload) {
        finished.add(server.respondPrepareUpload(sessionId: event.sessionId, acceptedFileIds: event.files.keys.toList()));
      } else if (event is RsServerEvent_FileUpload) {
        finished.add(() async {
          try {
            final previous = targets[event.fileId];
            final target = previous == null
                ? await prepareFileSaveTarget(
                    destinationDirectory: destination.path,
                    cacheDirectory: destination.path,
                    fileName: event.file.fileName,
                    saveToGallery: false,
                    isImage: false,
                    createdDirectories: createdDirectories,
                    reservations: sessionScopeReceivePathReservations,
                  )
                : await reopenFileSaveTarget(previous);
            targets[event.fileId] = target;
            attempts.putIfAbsent(event.fileId, () => []).add(target.displayPath);
            // No destination is published before every parallel allocation has
            // completed. Without session reservations these all select (2).
            if (targets.length == fileCount && !allTargetsReserved.isCompleted) allTargetsReserved.complete();
            await allTargetsReserved.future.timeout(const Duration(seconds: 15));
            await server
                .respondFileUpload(
                  sessionId: event.sessionId,
                  fileId: event.fileId,
                  path: target.path,
                  fileDescriptor: target.fileDescriptor,
                  fileSize: event.file.size,
                )
                .drain<void>();
          } catch (error) {
            failures.add((event.fileId, error));
          }
        }());
      }
    });
    try {
      final prepare = await client.postUrl(Uri.parse('$base/prepare-upload'));
      prepare.headers.contentType = ContentType.json;
      prepare.write(
        jsonEncode({
          'info': {'alias': 'v2 sender', 'version': '2.2', 'fingerprint': 'sender', 'port': 53317, 'protocol': 'http'},
          'files': {
            for (final entry in bytes.entries)
              entry.key: {
                'id': entry.key,
                'fileName': incomingName,
                'size': entry.value.length,
                'fileType': 'application/octet-stream',
                'sha256': sha256.convert(entry.value).toString(),
              },
          },
        }),
      );
      final prepared = await prepare.close();
      expect(prepared.statusCode, 200);
      final session = jsonDecode(await utf8.decoder.bind(prepared).join()) as Map<String, dynamic>;
      final tokens = (session['files'] as Map).cast<String, String>();
      expect(tokens.keys.toSet(), bytes.keys.toSet());
      Future<int> upload(String id, {bool corrupt = false}) async {
        final request = await client.postUrl(
          Uri.parse('$base/upload').replace(
            queryParameters: {
              'sessionId': session['sessionId'] as String,
              'fileId': id,
              'token': tokens[id]!,
            },
          ),
        );
        final body = Uint8List.fromList(bytes[id]!);
        if (corrupt) body[0] ^= 0xff;
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      final statuses = await Future.wait([
        for (final id in bytes.keys) upload(id, corrupt: id == 'file-0'),
      ]).timeout(const Duration(seconds: 30));
      await Future.wait(List.of(finished));
      expect(statuses.first, 422);
      expect(statuses.skip(1), everyElement(200));
      expect(failures.map((failure) => failure.$1), ['file-0']);
      expect(targets.values.map((target) => target.displayPath).toSet(), hasLength(fileCount));
      expect(await File(targets['file-0']!.path!).exists(), false, reason: 'failed checksum must not publish a partial final file');
      expect(await registry.list().length, 0);
      final reservedBeforeRetry = targets['file-0']!.displayPath;
      expect(await upload('file-0'), 200, reason: 'the original v2 token remains usable after checksum rejection');
      await Future.wait(List.of(finished));
      expect(attempts['file-0'], [reservedBeforeRetry, reservedBeforeRetry]);
      expect(failures, hasLength(1), reason: 'only the deliberately corrupted first attempt failed');
      for (final entry in bytes.entries) {
        expect(await File(targets[entry.key]!.path!).readAsBytes(), entry.value, reason: 'every incoming file retains its own original bytes');
      }
      expect(await original.readAsBytes(), [9, 8, 7, 6]);
      final entries = await original.parent.list().toList();
      expect(entries, hasLength(fileCount + 1));
      expect(entries.whereType<File>(), hasLength(fileCount + 1));
      expect(entries.where((entry) => p.basename(entry.path).startsWith('.legnasend-receive-')), isEmpty);
      expect(entries.where((entry) => entry.path.endsWith('.ls') || entry.path.endsWith('.part')), isEmpty);
      expect(await registry.list().length, 0);
      final report = jsonDecode(await cleanupReceiveCacheRegistry(limit: 100)) as Map;
      expect(report['removedFiles'], 0);
      expect(report['failed'], 0);
    } finally {
      client.close(force: true);
      await server.stop();
      await listener.cancel();
      await root.delete(recursive: true);
    }
  });
}
