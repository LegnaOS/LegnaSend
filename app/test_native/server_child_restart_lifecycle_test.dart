// Actual Flutter child isolate -> FRB -> native TCP listener and filesystem.
// Loopback scheduling stress is not physical-device or mobile acceptance.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:logging/logging.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';

class _RealHttp extends HttpOverrides {}

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
  throw TimeoutException('Native child lifecycle did not settle');
}

/// This test repeatedly releases/rebinds the exact same listener port. Do not
/// take an OS ephemeral port: after closing that reservation, concurrent test
/// HTTP clients can allocate it as their source port before the child binds.
/// The verified host ephemeral range is 49152..65535 (Linux defaults also
/// start above this fixture range). Probe wildcard, matching the native bind.
Future<int> _fixedListenerPort() async {
  final random = Random.secure();
  for (var attempt = 0; attempt < 128; attempt++) {
    final candidate = 20000 + random.nextInt(10000);
    try {
      final reservation = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
      await reservation.close();
      return candidate;
    } on SocketException {
      // Do not stop or replace anything already using this candidate.
    }
  }
  throw StateError('No free fixed fixture port in 20000..29999');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real child immediate start-stop-start reuses port and receives after obsolete stream finalization', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-child-restart-');
    final security = await generateSecurityContext();
    final port = await _fixedListenerPort();
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: security,
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Child lifecycle fixture', androidSdkInt: null),
      alias: 'Child lifecycle fixture',
      port: port,
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
          task: setupHttpServerIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final received = <IsolateTaskStreamResult<HttpServerEvent>>[];
    var nextId = 1;
    int send(BaseHttpServerTask data) {
      final id = nextId++;
      connector.sendToIsolate(
        SendToIsolateData(
          syncState: null,
          data: IsolateTask(id: id, data: data),
        ),
      );
      return id;
    }

    int start() => send(HttpServerStartTask(pin: null, verifyChecksums: true, web: _web, showToken: null));
    bool done(int id) => received.any((e) => e.id == id && e.done);
    bool started(int id) => received.any((e) => e.id == id && e.data is HttpServerStartedEvent);
    final subscription = connector.receiveFromIsolate.listen((result) {
      received.add(result);
      final event = result.data;
      if (event is HttpServerPrepareUploadEvent) {
        send(
          HttpServerPrepareUploadDecisionTask(
            sessionId: event.sessionId,
            config: HttpServerReceiveConfig(
              sessionId: event.sessionId,
              fileNameMap: {for (final e in event.files.entries) e.key: e.value.fileName},
              destinationDirectory: temp.path,
              cacheDirectory: temp.path,
              saveToGallery: false,
              androidSdkInt: null,
            ),
          ),
        );
      }
    });
    final client = _RealHttp().createHttpClient(null);
    final rounds = <Map<String, Object?>>[];
    Future<(int, String)> request(String path, List<int> bytes, {bool json = false}) async {
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
      request.persistentConnection = false;
      if (json) request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    }

    try {
      for (var round = 0; round < 12; round++) {
        // All three tasks enter the real child receive loop without waiting for a
        // started event or stop acknowledgement. No App ServerService gate hides it.
        final obsolete = start();
        final stop = send(HttpServerStopTask());
        final replacement = start();
        await _until(() => done(stop) && started(replacement));
        expect(received.where((e) => e.error != null), isEmpty);
        expect(
          (received.firstWhere((e) => e.id == replacement && e.data is HttpServerStartedEvent).data! as HttpServerStartedEvent).port,
          port,
          reason: 'Round $round must release and rebind the same fixed listener port; fallback is not accepted',
        );
        final bytes = utf8.encode('replacement $round\n中文\u0000native lifecycle\n');
        final digest = sha256.convert(bytes).toString();
        final fileName = 'replacement-$round-中文.txt';
        final (status, body) = await request(
          '/api/localsend/v2/prepare-upload',
          utf8.encode(
            jsonEncode({
              'info': {
                'alias': 'Original v2 fixture',
                'version': '2.2',
                'deviceModel': 'fixture',
                'deviceType': 'desktop',
                'fingerprint': 'fixture-sender',
                'port': 53317,
                'protocol': 'http',
                'download': false,
              },
              'files': {
                'file': {'id': 'file', 'fileName': fileName, 'size': bytes.length, 'fileType': 'text/plain', 'sha256': digest},
              },
            }),
          ),
          json: true,
        );
        expect(status, 200, reason: body);
        final preparation = jsonDecode(body) as Map<String, dynamic>;
        final oldDoneAtPrepareResponse = done(obsolete);
        final sessionId = preparation['sessionId'] as String;
        final token = (preparation['files'] as Map<String, dynamic>)['file'] as String;
        // Before uploading, require old-stream finalization too. Native scheduling
        // may finish it before or after prepare; this stress test does not force
        // that order (the service unit tests deterministically force stale owners).
        await _until(() => done(obsolete));
        final query = Uri(queryParameters: {'sessionId': sessionId, 'fileId': 'file', 'token': token}).query;
        final (uploadStatus, uploadBody) = await request('/api/localsend/v2/upload?$query', bytes);
        expect(uploadStatus, 200, reason: uploadBody);
        await _until(() => received.any((e) => e.id == replacement && e.data is HttpServerFileUploadResultEvent));
        final result = received.where((e) => e.id == replacement).map((e) => e.data).whereType<HttpServerFileUploadResultEvent>().single;
        expect(result.error, isNull);
        expect(result.sessionId, sessionId);
        final output = File('${temp.path}/$fileName');
        expect(await output.readAsBytes(), bytes);
        expect(sha256.convert(await output.readAsBytes()).toString(), digest);
        final finalStop = send(HttpServerStopTask());
        await _until(() => done(finalStop) && done(replacement));
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await probe.close();
        rounds.add({
          'round': round,
          'port': port,
          'oldStartedEvents': received.where((e) => e.id == obsolete && e.data is HttpServerStartedEvent).length,
          'oldDone': done(obsolete),
          'oldDoneAtPrepareResponse': oldDoneAtPrepareResponse,
          'newDone': done(replacement),
          'bytes': bytes.length,
          'sha256': digest,
          'rebindAfterStop': true,
        });
      }
      expect(received.where((e) => e.error != null), isEmpty);
      expect(rounds, hasLength(12));
      final report = File('../build/test-results/batch28/send-recovery/child-listener-results.json');
      await report.parent.create(recursive: true);
      await report.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
          'boundary': 'Real Flutter child isolate, FRB native server, loopback original v2 HTTP, disk; not physical/mobile acceptance',
          'platform': Platform.operatingSystem,
          'rounds': rounds,
        })}\n',
      );
    } finally {
      client.close(force: true);
      final stop = send(HttpServerStopTask());
      try {
        await _until(() => done(stop));
      } finally {
        await subscription.cancel();
        connector.isolate.kill();
        await temp.delete(recursive: true);
      }
    }
  });
}
