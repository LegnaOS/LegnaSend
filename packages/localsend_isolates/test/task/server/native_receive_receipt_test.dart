// Real native server and child isolate; original v2 HTTP and actual disk saves.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as native;
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:logging/logging.dart';

import '../../support/native_bridge.dart';

class _RealHttp extends HttpOverrides {}

class _Initial extends InitialData {
  final SendPort control;
  _Initial({required super.syncState, required this.control}) : super(logLevel: Level.WARNING);
}

Future<void> _setup(
  Stream<SendToIsolateData<IsolateTask<BaseHttpServerTask>>> messages,
  void Function(IsolateTaskStreamResult<HttpServerEvent>) emit,
  InitialData initial,
) async {
  final control = (initial as _Initial).control;
  final releases = ReceivePort();
  final oldGate = Completer<void>();
  releases.listen((_) {
    if (!oldGate.isCompleted) oldGate.complete();
  });
  control.send(releases.sendPort);
  await setupHttpServerIsolate(
    messages,
    emit,
    initial,
    afterSave: (receipt) async {
      control.send(receipt);
      if (receipt.senderAlias == 'old') await oldGate.future;
    },
  );
}

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

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Native receipt state did not arrive');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('same-listener new receive finishes before delayed old success receipt with reused peer file ID', () async {
    final repository = Directory.current.parent.parent.path;
    await initializeWorkspaceNativeBridge(repository);
    final identity = await native.generateSecurityContext();
    final temp = await Directory.systemTemp.createTemp('legnasend-receipts-');
    final controls = ReceivePort();
    SendPort? release;
    final saved = <HttpServerReceiveReceipt>[];
    final controlSubscription = controls.listen((event) {
      if (event is SendPort) release = event;
      if (event is HttpServerReceiveReceipt) saved.add(event);
    });
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: StoredSecurityContext(
        privateKey: identity.privateKey,
        publicKey: identity.publicKey,
        certificate: identity.certificate,
        certificateHash: identity.certificateHash,
      ),
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Receipt fixture', androidSdkInt: null),
      alias: 'Receipt fixture',
      port: 0,
      discoveryPort: 53317,
      networkWhitelist: null,
      networkBlacklist: null,
      protocol: ProtocolType.http,
      multicastGroup: '224.0.0.167',
      discoveryTimeout: 1000,
      serverRunning: false,
      download: false,
    );
    final connector =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpServerEvent>, SendToIsolateData<IsolateTask<BaseHttpServerTask>>, InitialData>(
          task: _setup,
          param: _Initial(syncState: sync, control: controls.sendPort),
        );
    final events = <IsolateTaskStreamResult<HttpServerEvent>>[];
    var sequence = 1;
    int send(BaseHttpServerTask data) {
      final id = sequence++;
      connector.sendToIsolate(
        SendToIsolateData(
          syncState: null,
          data: IsolateTask(id: id, data: data),
        ),
      );
      return id;
    }

    final subscription = connector.receiveFromIsolate.listen((response) {
      events.add(response);
      final event = response.data;
      if (event is HttpServerPrepareUploadEvent) {
        send(
          HttpServerPrepareUploadDecisionTask(
            sessionId: event.sessionId,
            config: HttpServerReceiveConfig(
              sessionId: event.sessionId,
              fileNameMap: {'reused-id': 'saved-${event.info.alias}-中文.txt'},
              destinationDirectory: temp.path,
              cacheDirectory: temp.path,
              saveToGallery: false,
              androidSdkInt: null,
              senderAlias: event.info.alias,
            ),
          ),
        );
      }
    });
    final client = _RealHttp().createHttpClient(null);
    var port = 0;
    Future<(int, String)> request(String path, List<int> bytes, {bool json = false}) async {
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
      if (json) request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    }

    Future<Map<String, dynamic>> prepare(String alias, List<int> bytes) async {
      final (status, body) = await request(
        '/api/localsend/v2/prepare-upload',
        utf8.encode(
          jsonEncode({
            'info': {
              'alias': alias,
              'version': '2.2',
              'deviceType': 'desktop',
              'fingerprint': 'same-fixture-peer',
              'port': 53317,
              'protocol': 'http',
              'download': false,
            },
            'files': {
              'reused-id': {
                'id': 'reused-id',
                'fileName': 'wire-source.txt',
                'size': bytes.length,
                'fileType': 'text/plain',
                'sha256': sha256.convert(bytes).toString(),
              },
            },
          }),
        ),
        json: true,
      );
      expect(status, 200, reason: body);
      return jsonDecode(body) as Map<String, dynamic>;
    }

    Future<int> upload(Map<String, dynamic> preparation, List<int> bytes) async {
      final query = Uri(
        queryParameters: {
          'sessionId': preparation['sessionId'] as String,
          'fileId': 'reused-id',
          'token': (preparation['files'] as Map<String, dynamic>)['reused-id'] as String,
        },
      ).query;
      return (await request('/api/localsend/v2/upload?$query', bytes)).$1;
    }

    List<HttpServerFileUploadResultEvent> results(String session) =>
        events.map((e) => e.data).whereType<HttpServerFileUploadResultEvent>().where((e) => e.sessionId == session).toList();
    try {
      send(HttpServerStartTask(pin: null, verifyChecksums: true, web: _web, showToken: null));
      await _until(() => release != null && events.any((e) => e.data is HttpServerStartedEvent));
      port = events.map((e) => e.data).whereType<HttpServerStartedEvent>().single.port;
      final oldBytes = utf8.encode('old file before next session\n中文\u0000');
      final newBytes = utf8.encode('new file after next prepare\n新的\u0000');
      final old = await prepare('old', oldBytes);
      expect(await upload(old, oldBytes), 200);
      await _until(() => saved.any((r) => r.senderAlias == 'old'));
      expect(results(old['sessionId'] as String), isEmpty);
      expect(await File('${temp.path}/saved-old-中文.txt').readAsBytes(), oldBytes);

      final next = await prepare('new', newBytes);
      expect(next['sessionId'], isNot(old['sessionId']));
      expect(await upload(next, newBytes), 200);
      await _until(() => results(next['sessionId'] as String).isNotEmpty);
      expect(results(old['sessionId'] as String), isEmpty, reason: 'Old receipt remains deliberately delayed');
      final fresh = results(next['sessionId'] as String).single;
      expect(fresh.error, isNull);
      expect(fresh.receipt!.fileName, 'saved-new-中文.txt');
      expect(fresh.receipt!.senderAlias, 'new');
      expect(fresh.receipt!.fileType, FileType.text);
      expect(fresh.receipt!.fileSize, newBytes.length);
      expect(fresh.receipt!.timestamp.isUtc, true);
      release!.send('release');
      await _until(() => results(old['sessionId'] as String).isNotEmpty);
      final delayed = results(old['sessionId'] as String).single;
      expect(delayed.error, isNull);
      expect(delayed.receipt!.fileName, 'saved-old-中文.txt');
      expect(delayed.receipt!.senderAlias, 'old');
      expect(delayed.receipt!.fileSize, oldBytes.length);
      expect(delayed.receipt!.fileType, FileType.text);
      expect(delayed.receipt!.timestamp.isUtc, true);
      expect(delayed.receipt!.timestamp.isBefore(fresh.receipt!.timestamp), true);
      expect(delayed.receipt!.receiptId, isNot(fresh.receipt!.receiptId));
      expect(delayed.receipt!.receiptId, startsWith('native:'));
      expect(await File(delayed.path!).readAsBytes(), oldBytes);
      expect(await File(fresh.path!).readAsBytes(), newBytes);
      expect(delayed.savedToGallery, false);
      expect(fresh.savedToGallery, false);

      // A failed checksum publishes neither a final file nor a success receipt;
      // the same original session/token can retry the whole file successfully.
      final retryBytes = utf8.encode('retry after checksum mismatch\n');
      final retry = await prepare('retry', retryBytes);
      final wrong = List<int>.from(retryBytes)..[0] ^= 1;
      expect(await upload(retry, wrong), 422);
      await _until(() => results(retry['sessionId'] as String).isNotEmpty);
      final failed = results(retry['sessionId'] as String).single;
      expect(failed.error, isNotNull);
      expect(failed.receipt, isNull);
      expect(saved.where((r) => r.senderAlias == 'retry'), isEmpty);
      expect(await upload(retry, retryBytes), 200);
      await _until(() => results(retry['sessionId'] as String).length == 2);
      final retried = results(retry['sessionId'] as String).last;
      expect(retried.error, isNull);
      expect(retried.receipt!.senderAlias, 'retry');
      expect(retried.receipt!.fileName, 'saved-retry-中文.txt');
      expect(await File(retried.path!).readAsBytes(), retryBytes);
      expect({delayed.receipt!.receiptId, fresh.receipt!.receiptId, retried.receipt!.receiptId}, hasLength(3));
      expect(events.where((e) => e.error != null), isEmpty);
      final report = File('$repository/build/test-results/batch29/receipts/native-ordering-results.json');
      await report.parent.create(recursive: true);
      await report.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
          'boundary': 'One listener on macOS loopback, real child/FRB/native disk; no stop/restart or physical mobile claims',
          'port': port,
          'deliveredAliases': events.map((e) => e.data).whereType<HttpServerFileUploadResultEvent>().where((e) => e.receipt != null).map((e) => e.receipt!.senderAlias).toList(),
          'receipts': [
            for (final result in [delayed, fresh, retried]) {
                'receiptId': result.receipt!.receiptId,
                'name': result.receipt!.fileName,
                'sender': result.receipt!.senderAlias,
                'bytes': result.receipt!.fileSize,
                'timestamp': result.receipt!.timestamp.toIso8601String(),
                'sha256': sha256.convert(await File(result.path!).readAsBytes()).toString(),
              },
          ],
          'checksumFailureReceipt': failed.receipt,
        })}\n',
      );
    } finally {
      release?.send('release');
      client.close(force: true);
      final stop = send(HttpServerStopTask());
      await _until(() => events.any((e) => e.id == stop && e.done));
      await subscription.cancel();
      connector.isolate.kill();
      await controlSubscription.cancel();
      controls.close();
      await temp.delete(recursive: true);
    }
  });
}
