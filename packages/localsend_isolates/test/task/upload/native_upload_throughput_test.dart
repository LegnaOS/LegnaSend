// Real FRB client -> local TCP meter -> Rust v2 server -> disk. This is not
// original-peer, physical-network, SAF, mobile-background or full-UI evidence.
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/model/device.dart' as device;
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as crypto;
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/upload/http_upload.dart';
import 'package:localsend_isolates/util/upload_scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

const _web = WebParams(
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
);

class _Meter {
  final ServerSocket listener;
  final Set<Socket> sockets = {};
  late final StreamSubscription<Socket> subscription;
  int connections = 0;
  int sent = 0;
  int received = 0;
  _Meter._(this.listener, int upstreamPort) {
    subscription = listener.listen((incoming) async {
      connections++;
      sockets.add(incoming);
      Socket? outgoing;
      try {
        outgoing = await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
        sockets.add(outgoing);
        await Future.wait([
          incoming
              .map<List<int>>((bytes) {
                sent += bytes.length;
                return bytes;
              })
              .pipe(outgoing),
          outgoing
              .map<List<int>>((bytes) {
                received += bytes.length;
                return bytes;
              })
              .pipe(incoming),
        ]);
      } catch (_) {
        // Closing the fixture interrupts idle pooled sockets.
      } finally {
        incoming.destroy();
        outgoing?.destroy();
        sockets.remove(incoming);
        sockets.remove(outgoing);
      }
    });
  }
  static Future<_Meter> start(int port) async => _Meter._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), port);
  Future<void> close() async {
    await subscription.cancel();
    await listener.close();
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
  }
}

Uint8List _bytes(int index, int size) => Uint8List.fromList(List.generate(size, (offset) => (index * 31 + offset * 17) & 255));

void main() {
  final count = int.parse(Platform.environment['LEGNASEND_UPLOAD_COUNT'] ?? '40');
  final rounds = int.parse(Platform.environment['LEGNASEND_UPLOAD_ROUNDS'] ?? '1');
  final mixed = Platform.environment['LEGNASEND_UPLOAD_MIXED'] == '1';
  final delayMs = int.parse(Platform.environment['LEGNASEND_UPLOAD_TARGET_DELAY_MS'] ?? '0');
  final output = Platform.environment['LEGNASEND_UPLOAD_REPORT'];
  final results = <Map<String, Object>>[];
  late crypto.SecurityContext identity;
  late Directory root;
  late Map<String, FileDto> files;
  setUpAll(() async {
    expect(count, inInclusiveRange(1, 10000));
    expect(rounds, inInclusiveRange(1, 5));
    expect(delayMs, inInclusiveRange(0, 100));
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
    expect(File(library).existsSync(), true, reason: 'Build rust_lib_localsend_app before this integration test');
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    identity = await crypto.generateSecurityContext();
    root = await Directory.systemTemp.createTemp('legnasend-upload-bench-');
    await configureReceiveCacheRegistry(directory: p.join(root.path, 'receive-registry'));
    files = {};
    for (var i = 0; i < count; i++) {
      final id = 'file-$i';
      final size = mixed && i % 16 == 0 ? 1024 * 1024 : 4096;
      final bytes = _bytes(i, size);
      final name = 'folder-${i % 20}/子目录/file $i.bin';
      final source = File(p.join(root.path, 'source', name));
      await source.parent.create(recursive: true);
      await source.writeAsBytes(bytes);
      files[id] = FileDto(
        id: id,
        fileName: name,
        size: BigInt.from(size),
        fileType: 'application/octet-stream',
        sha256: sha256.convert(bytes).toString(),
      );
    }
  });
  tearDownAll(() async {
    if (output != null) {
      final report = File(output);
      await report.parent.create(recursive: true);
      await report.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'dart': Platform.version,
          'profile': mixed ? 'mixed-1MiB-every-16-files' : '4096-byte-files',
          'targetDelayMs': delayMs,
          'boundary': 'local TCP meter; real native client/FRB/service/server/disk; excludes parent UI, physical network and original peer',
          'runs': results,
        })}\n',
      );
    }
    await root.delete(recursive: true);
  });

  for (final tls in [false, true]) {
    test('${tls ? 'HTTPS pinned' : 'HTTP'} original v2 files: two-lane baseline versus bounded small-file scheduler', () async {
      for (var round = 0; round < rounds; round++) {
        // Alternate ordering to avoid attributing all warm-cache benefit to new scheduling.
        for (final optimized in round.isEven ? [false, true] : [true, false]) {
          final protocol = tls ? ProtocolType.https : ProtocolType.http;
          final destination = Directory(p.join(root.path, 'received-${tls ? 1 : 0}-$round-$optimized'));
          await destination.create();
          // Pre-create directories for both policies; directory setup is outside timing.
          for (final file in files.values) {
            await Directory(p.dirname(p.join(destination.path, file.fileName))).create(recursive: true);
          }
          final server = await startServer(
            port: 0,
            tls: tls ? TlsConfig(cert: identity.certificate, privateKey: identity.privateKey) : null,
            alias: 'Bench receiver',
            version: '2.2',
            deviceModel: null,
            deviceType: null,
            fingerprint: identity.certificateHash,
            pin: null,
            verifyChecksums: true,
            web: _web,
            showToken: null,
          );
          final writes = <Future<void>>[];
          final errors = <Object>[];
          final writing = <String>{};
          final sending = <String>{};
          final ends = <RsServerEvent_SessionEnd>[];
          var prepares = 0;
          var uploads = 0;
          final listener = server.listen().listen((event) {
            if (event is RsServerEvent_PrepareUpload) {
              prepares++;
              unawaited(server.respondPrepareUpload(sessionId: event.sessionId, acceptedFileIds: event.files.keys.toList()));
            } else if (event is RsServerEvent_FileUpload) {
              uploads++;
              writing.add(event.fileId);
              writes.add(() async {
                try {
                  if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
                  await server
                      .respondFileUpload(
                        sessionId: event.sessionId,
                        fileId: event.fileId,
                        path: p.join(destination.path, event.file.fileName),
                        fileSize: event.file.size,
                      )
                      .drain<void>();
                } catch (error) {
                  errors.add(error);
                } finally {
                  writing.remove(event.fileId);
                }
              }());
            } else if (event is RsServerEvent_SessionEnd) {
              ends.add(event);
            }
          });
          final meter = await _Meter.start(await server.port());
          final targetPort = meter.listener.port;
          final client = createClient(
            privateKey: identity.privateKey,
            cert: identity.certificate,
            version: LsHttpClientVersion.v2,
            expectedFingerprint: identity.certificateHash,
          );
          final cancel = createCancellationToken();
          Timer? sampler;
          try {
            final total = Stopwatch()..start();
            final prepared = await client.prepareUpload(
              protocol: protocol,
              ip: '127.0.0.1',
              port: targetPort,
              payload: PrepareUploadRequestDto(
                info: RegisterDto(
                  alias: 'Bench sender',
                  version: '2.2',
                  token: identity.certificateHash,
                  port: targetPort,
                  protocol: protocol,
                  hasWebInterface: false,
                ),
                files: files,
              ),
              cancelToken: cancel,
            );
            final session = prepared.response!;
            expect(session.files.length, count);
            final target = device.Device.empty.copyWith(
              ip: '127.0.0.1',
              port: targetPort,
              https: tls,
              fingerprint: identity.certificateHash,
            );
            var peakActive = 0;
            var active = 0;
            var progressEvents = 0;
            var completed = 0;
            final startRss = ProcessInfo.currentRss;
            var peakRss = startRss;
            sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
              peakRss = math.max(peakRss, ProcessInfo.currentRss);
            });
            final transfer = Stopwatch()..start();
            Future<void> upload(FileDto file) async {
              active++;
              sending.add(file.id);
              peakActive = math.max(peakActive, active);
              try {
                await const HttpUploadService().upload(
                  client: client,
                  stream: null,
                  path: p.join(root.path, 'source', file.fileName),
                  fileDescriptor: null,
                  contentLength: file.size.toInt(),
                  target: target,
                  remoteSessionId: session.sessionId,
                  fileId: file.id,
                  token: session.files[file.id]!,
                  onSendProgress: (progress) {
                    expect(progress, inInclusiveRange(0.0, 1.0));
                    progressEvents++;
                  },
                  cancelToken: cancel,
                );
                completed++;
              } finally {
                active--;
                sending.remove(file.id);
              }
            }

            Future<void> execute() async {
              if (optimized) {
                await UploadScheduler().run<FileDto>(
                  files.values.toList(),
                  sizeOf: (file) => file.size.toInt(),
                  isCancelled: () => false,
                  upload: upload,
                );
              } else {
                await Pool(2).forEach<FileDto, void>(files.values, upload).drain<void>();
              }
            }

            await execute().timeout(
              const Duration(seconds: 60),
              onTimeout: () =>
                  throw StateError('Upload stalled: completed=$completed uploads=$uploads sending=$sending writing=${writing.take(12).toList()}'),
            );
            transfer.stop();
            total.stop();
            sampler.cancel();
            await Future.wait(writes).timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('Writes stalled: $writing'));
            expect(errors, isEmpty);
            expect(completed, count);
            expect(prepares, 1);
            expect(uploads, count);
            expect(ends, hasLength(1));
            expect(peakActive, lessThanOrEqualTo(optimized ? 6 : 2));
            // Active file permits are not a lifetime TCP-connection limit: the
            // TLS pool may race during warmup. Record the real count and reject
            // connection-per-file behavior for a sufficiently large batch.
            if (count >= 20) expect(meter.connections, lessThan(count));
            final byteCount = files.values.fold<int>(0, (n, file) => n + file.size.toInt());
            for (final entry in files.entries) {
              final actual = await File(p.join(destination.path, entry.value.fileName)).readAsBytes();
              expect(sha256.convert(actual).toString(), entry.value.sha256, reason: entry.key);
              expect(actual, await File(p.join(root.path, 'source', entry.value.fileName)).readAsBytes(), reason: entry.key);
            }
            expect(await destination.list(recursive: true).where((item) => item is File).length, count);
            expect(await Directory(p.join(root.path, 'receive-registry')).list().length, 0);
            final row = <String, Object>{
              'tls': tls,
              'round': round,
              'policy': optimized ? 'bounded-small' : 'baseline-two',
              'files': count,
              'bytes': byteCount,
              'totalMs': total.elapsedMicroseconds / 1000,
              'transferMs': transfer.elapsedMicroseconds / 1000,
              'filesPerSecond': count * 1000000 / transfer.elapsedMicroseconds,
              'bytesPerSecond': byteCount * 1000000 / transfer.elapsedMicroseconds,
              'connections': meter.connections,
              'prepareRequests': prepares,
              'uploadRequests': uploads,
              'wireSent': meter.sent,
              'wireReceived': meter.received,
              'peakActive': peakActive,
              'progressEvents': progressEvents,
              'startProcessRss': startRss,
              'peakProcessRss': peakRss,
              'verifiedFiles': count,
            };
            results.add(row);
            // ignore: avoid_print
            print(jsonEncode(row));
          } finally {
            sampler?.cancel();
            cancel.cancel();
            client.dispose();
            await meter.close();
            await server.stop();
            await listener.cancel();
            await Future.wait(writes);
          }
        }
      }
    });
  }
}
