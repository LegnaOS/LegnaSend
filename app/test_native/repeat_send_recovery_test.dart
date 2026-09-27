@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/send_session_lookup.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/rust/api/http.dart' as native;
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/upload_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

/// Only the timeout case changes the real Rust client's request deadline.
/// Production leaves prepare requests open for human approval; no fake response
/// or app-level Future.timeout replaces the native cancellation/error path.
class _Clients extends HttpClientCollection {
  final StoredSecurityContext security;
  int? timeoutMs;
  _Clients(this.security)
    : super(
        privateKey: security.privateKey,
        certificate: security.certificate,
        discovery: native.createClient(privateKey: security.privateKey, cert: security.certificate, version: native.LsHttpClientVersion.v2),
      );
  @override
  native.RsHttpClient pinnedTo(String fingerprint, {LocalSendRoute? localRoute}) => native.createClient(
    privateKey: security.privateKey,
    cert: security.certificate,
    version: native.LsHttpClientVersion.v2,
    expectedFingerprint: fingerprint,
    localAddress: localRoute?.localAddress,
    interfaceName: localRoute?.interfaceName,
    timeoutMs: timeoutMs,
  );
}

class _Discovery extends NearbyDevicesService {
  final Device peer;
  _Discovery(this.peer, IsolateController isolates)
    : super(isolateController: isolates, favoriteService: FavoritesService(MockPersistenceService()), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {peer.fingerprint: peer}, signalingDevices: {});
}

Future<void> _until(bool Function() predicate, {Duration timeout = const Duration(seconds: 15)}) async {
  final clock = Stopwatch()..start();
  while (!predicate()) {
    if (clock.elapsed > timeout) throw TimeoutException('Sender recovery condition did not arrive', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// This is a separately launched original-wire HTTP fixture, not the LocalSend
/// application. A killed process simulates peer disappearance, not power loss.
class _Peer {
  final Process process;
  final List<Map<String, dynamic>> events = [];
  final List<String> stderr = [];
  late final StreamSubscription<String> _out, _err;
  late final int port;
  int command = 0;
  bool stopped = false;
  _Peer(this.process) {
    _out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      events.add(jsonDecode(line) as Map<String, dynamic>);
    });
    _err = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(stderr.add);
  }
  static Future<_Peer> start(String dart, File script, Directory destination, {int port = 0}) async {
    final peer = _Peer(await Process.start(dart, [script.path, destination.path, '$port']));
    await _until(() => peer.events.any((e) => e['event'] == 'ready'));
    peer.port = peer.events.firstWhere((e) => e['event'] == 'ready')['port'] as int;
    return peer;
  }

  Future<void> mode(String mode) async {
    final id = ++command;
    process.stdin.writeln(jsonEncode({'op': 'mode', 'mode': mode, 'id': id}));
    await process.stdin.flush();
    await _until(() => events.any((e) => e['event'] == 'ack' && e['id'] == id));
  }

  Future<int> kill() async {
    stopped = true;
    if (!process.kill(Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill)) throw StateError('Fixture process did not terminate');
    return process.exitCode.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    if (!stopped) {
      stopped = true;
      process.stdin.writeln('{"op":"stop"}');
      await process.stdin.flush();
      await process.exitCode.timeout(const Duration(seconds: 10));
    }
    await _out.cancel();
    await _err.cancel();
  }
}

const _peerSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
void report(Map<String,dynamic> value) => stdout.writeln(jsonEncode(value));
Future<void> main(List<String> args) async {
  final root = Directory(args[0]); await root.create(recursive:true);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, int.parse(args[1]));
  var nextMode = 'success', serial = 0;
  final sessions = <String,Map<String,dynamic>>{};
  final held = <HttpRequest>[];
  server.listen((request) async {
    try {
      final path = request.uri.path;
      if (request.method != 'POST') throw StateError('Only original v2 POST operations are expected');
      if (path == '/api/localsend/v2/prepare-upload') {
        final payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String,dynamic>;
        if (payload.keys.toSet().difference({'info','files'}).isNotEmpty || payload.length != 2) throw StateError('Unexpected prepare fields');
        if ((payload['info'] as Map)['protocol'] != 'http') throw StateError('Fixture expects HTTP');
        final files = payload['files'] as Map<String,dynamic>;
        if (files.length != 1) throw StateError('Expected exactly one original file');
        final entry = files.entries.single, file = entry.value as Map<String,dynamic>;
        if (file['id'] != entry.key || file['sha256'] == null) throw StateError('File identity/checksum absent');
        if (file.keys.toSet().difference({'id','fileName','size','fileType','sha256','preview','metadata'}).isNotEmpty) throw StateError('Non-original file fields');
        final mode = nextMode; nextMode = 'success';
        report({'event':'prepare','mode':mode,'name':file['fileName'],'size':file['size'],'sha256':file['sha256']});
        if (['hold','timeout','process_disconnect'].contains(mode)) { held.add(request); return; }
        if (['403','409','429'].contains(mode)) {
          request.response.statusCode = int.parse(mode); await request.response.close(); return;
        }
        if (mode == 'socket_disconnect') {
          final socket = await request.response.detachSocket(writeHeaders:false); socket.destroy();
          report({'event':'prepare_disconnected'}); return;
        }
        if (sessions.isNotEmpty) {
          report({'event':'fault','error':'Previous accepted session still owns receiver slot'});
          request.response.statusCode=409; await request.response.close(); return;
        }
        final session='fixture-${++serial}'; sessions[session]={'fileId':entry.key,'file':file,'mode':mode};
        request.response.headers.contentType=ContentType.json;
        request.response.write(jsonEncode({'sessionId':session,'files':{entry.key:'token-${entry.key}'}}));
        await request.response.close(); return;
      }
      if (path == '/api/localsend/v2/upload') {
        final q=request.uri.queryParameters, session=q['sessionId'], saved=sessions[session];
        if (q.keys.toSet().difference({'sessionId','fileId','token'}).isNotEmpty || q.length!=3 || saved==null ||
          q['fileId']!=saved['fileId'] || q['token']!='token-${saved['fileId']}') throw StateError('Invalid original upload credentials');
        final file=saved['file'] as Map<String,dynamic>;
        if (saved['mode']=='mid_upload_disconnect') {
          final first=await request.first;
          report({'event':'partial','name':file['fileName'],'receivedPrefix':first.length,'declaredSize':file['size']});
          final socket=await request.response.detachSocket(writeHeaders:false); socket.destroy(); return;
        }
        final name=file['fileName'] as String;
        if (name.contains('..') || name.startsWith('/')) throw StateError('Unexpected fixture path');
        final output=File('${root.path}/$name'); await output.parent.create(recursive:true);
        final sink=output.openWrite(); var count=0;
        await for(final chunk in request) { sink.add(chunk); count+=chunk.length; }
        await sink.close();
        if(count!=file['size']) throw StateError('Upload length differs from prepare');
        sessions.remove(session);
        report({'event':'saved','name':name,'size':count,'sha256':file['sha256']});
        await request.response.close(); return;
      }
      if (path == '/api/localsend/v2/cancel') {
        await request.drain<void>(); final id=request.uri.queryParameters['sessionId'];sessions.remove(id);
        report({'event':'cancel','sessionId':id}); await request.response.close(); return;
      }
      throw StateError('Unexpected endpoint $path');
    } catch(error) {
      report({'event':'fault','error':'$error'});
      try { request.response.statusCode=500; await request.response.close(); } catch(_) {}
    }
  });
  report({'event':'ready','port':server.port,'pid':pid});
  await for(final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final command=jsonDecode(line) as Map<String,dynamic>;
    if(command['op']=='mode') { nextMode=command['mode'] as String; report({'event':'ack','id':command['id']}); }
    if(command['op']=='stop') { await server.close(force:true); exit(0); }
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real sender failures release same-device FIFO slot and the next original-wire task saves correct bytes', () async {
    final repository = Directory.current.parent;
    await initializeWorkspaceNativeBridge(repository.path);
    final evidence = Directory('${repository.path}/build/test-results/batch28/send-recovery')..createSync(recursive: true);
    final temp = await Directory.systemTemp.createTemp('legnasend-repeat-sender-');
    final script = File('${temp.path}/original_peer.dart');
    await script.writeAsString(_peerSource);
    final destination = Directory('${temp.path}/peer-downloads');
    final dart = '${repository.path}/.fvm/flutter_sdk/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
    final peers = <_Peer>[];
    var peer = await _Peer.start(dart, script, destination);
    peers.add(peer);
    final security = await generateSecurityContext();
    final clients = _Clients(security);
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: security,
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Sender recovery fixture', androidSdkInt: null),
      alias: 'Sender',
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
    final upload =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpUploadEvent>, SendToIsolateData<IsolateTask<BaseHttpUploadTask>>, InitialData>(
          task: setupHttpUploadIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final persistence = MockPersistenceService();
    when(persistence.getSecurityContext()).thenReturn(security);
    when(persistence.getCreateChecksums()).thenReturn(true);
    final target = Device.empty.copyWith(
      ip: '127.0.0.1',
      port: peer.port,
      https: false,
      fingerprint: 'A' * 64,
      alias: 'Original wire subprocess',
      version: '2.2',
      channels: [HttpChannel(host: '127.0.0.1', port: peer.port, https: false)],
    );
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        httpProvider.overrideWithBuilder((_) => clients),
        deviceFullInfoProvider.overrideWithBuilder((_) => target.copyWith(alias: 'Sender', fingerprint: security.certificateHash)),
        nearbyDevicesProvider.overrideWithNotifier((ref) => _Discovery(target, ref.notifier(parentIsolateProvider))),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: upload, httpServer: null),
          ),
        ),
      ],
    );
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receive',
        titleSending: 'Send',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '$h:$m',
      ),
    );
    final queue = container.notifier(sendQueueProvider);
    final channel = target.channels.whereType<HttpChannel>().single;
    final results = <Map<String, dynamic>>[];
    final ordinary = utf8.encode('LegnaSend original bytes\u0000中文🙂\n');
    final large = List<int>.generate(8 * 1024 * 1024, (i) => (i * 17 + 3) % 251);
    CrossFile source(String name, List<int> bytes) => CrossFile(
      name: name,
      fileType: FileType.other,
      size: bytes.length,
      path: null,
      bytes: bytes,
      asset: null,
      thumbnail: null,
      lastModified: null,
      lastAccessed: null,
    );
    SendJob job(String id) => container.read(sendQueueProvider).firstWhere((entry) => entry.id == id);
    Future<SendJob> terminal(String id) async {
      await _until(() => job(id).terminal);
      return job(id);
    }

    try {
      for (final mode in ['hold', '403', '409', '429', 'timeout', 'socket_disconnect', 'process_disconnect', 'mid_upload_disconnect']) {
        clients.timeoutMs = mode == 'timeout' ? 1000 : null;
        await peer.mode(mode);
        final beforeEvents = peer.events.length;
        final failedName = 'failure-$mode.bin', nextName = '目录/恢复-$mode.bin';
        final attemptElapsed = Stopwatch()..start();
        final first = queue.enqueueExplicit(target, [source(failedName, mode == 'mid_upload_disconnect' ? large : ordinary)], channel);
        String? next;
        if (mode != 'process_disconnect') {
          next = queue.enqueueExplicit(target, [source(nextName, ordinary)], channel);
          expect(job(next).status, SendJobStatus.queued, reason: 'Same-device follow-up must wait for the current attempt');
        }
        await _until(() => peer.events.skip(beforeEvents).any((e) => e['event'] == 'prepare' && e['mode'] == mode));
        final elapsed = Stopwatch()..start();
        int? killedPid, exitCode;
        if (mode == 'hold') {
          expect(container.read(sendProvider)[first]!.status, SessionStatus.waiting);
          await queue.cancel(first);
        } else if (mode == 'process_disconnect') {
          killedPid = peer.process.pid;
          exitCode = await peer.kill();
        }
        final failed = await terminal(first);
        final firstSession = container.read(sendProvider)[first]!;
        final expected = switch (mode) {
          'hold' => SessionStatus.canceledBySender,
          '403' => SessionStatus.declined,
          '409' => SessionStatus.recipientBusy,
          '429' => SessionStatus.tooManyAttempts,
          _ => SessionStatus.finishedWithErrors,
        };
        expect(firstSession.status, expected);
        expect(failed.status, mode == 'hold' ? SendJobStatus.canceled : SendJobStatus.failed);
        expect(isActiveSendSession(firstSession), false);
        expect(firstSession.sendingTasks, isEmpty);
        final failureElapsedMs = attemptElapsed.elapsedMilliseconds;
        if (mode == 'timeout') expect(failureElapsedMs, greaterThanOrEqualTo(900));
        if (mode == 'process_disconnect') {
          peer = await _Peer.start(dart, script, destination, port: target.port);
          peers.add(peer);
          next = queue.enqueueExplicit(target, [source(nextName, ordinary)], channel);
        }
        final succeeded = await terminal(next!);
        expect(succeeded.status, SendJobStatus.succeeded);
        final output = File('${destination.path}/$nextName');
        expect(await output.readAsBytes(), ordinary);
        final digest = sha256.convert(await output.readAsBytes()).toString();
        expect(digest, sha256.convert(ordinary).toString());
        expect(container.read(sendProvider)[next]!.status, SessionStatus.finished);
        expect(container.read(sendProvider)[next]!.sendingTasks, isEmpty);
        expect(findDeviceSendSession(container.read(sendProvider).values, target, activeOnly: true), isNull);
        if (mode == 'mid_upload_disconnect') {
          final partial = peer.events.firstWhere((e) => e['event'] == 'partial');
          expect(partial['receivedPrefix'], greaterThan(0));
          expect(partial['receivedPrefix'], lessThan(partial['declaredSize'] as int));
          expect(peer.events.any((e) => e['event'] == 'cancel'), true);
          expect(File('${destination.path}/$failedName').existsSync(), false);
        }
        results.add({
          'scenario': mode,
          'failureStatus': firstSession.status.name,
          'queueFailure': failed.status.name,
          'nextStatus': succeeded.status.name,
          'elapsedAfterPrepareMs': elapsed.elapsedMilliseconds,
          'failureElapsedMs': failureElapsedMs,
          'nextBytes': ordinary.length,
          'nextSha256': digest,
          'nextName': nextName,
          'prepareTimeoutMs': clients.timeoutMs,
          'killedPid': killedPid,
          'exitCode': exitCode,
          'samePeerPort': target.port,
        });
      }
      expect(peers.expand((p) => p.events).where((e) => e['event'] == 'fault'), isEmpty);
      expect(peers.expand((p) => p.stderr), isEmpty);
      await File('${evidence.path}/results.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'baseline': '46855c0e',
          'transport': 'original LocalSend v2 HTTP over loopback',
          'nativeUploadIsolate': true,
          'peer': 'independent original-wire Dart subprocess, not original application',
          'processDeath': 'forced child-process termination; not physical power loss',
          'timeout': '1000 ms actual Rust client total timeout in timeout case only; production approval wait remains unchanged',
          'largeSourceBytes': large.length,
          'scenarios': results,
          'events': peers.map((p) => {'pid': p.process.pid, 'events': p.events, 'stderr': p.stderr}).toList(),
        }),
      );
    } finally {
      for (final entry in container.read(sendQueueProvider)) {
        if (!entry.terminal) await queue.cancel(entry.id);
      }
      for (final child in peers) {
        await child.close();
      }
      upload.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
