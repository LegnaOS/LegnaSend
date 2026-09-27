@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/child/upload_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/integration_api.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

class _Selection extends SelectedSendingFilesNotifier {
  final List<CrossFile> files;
  _Selection(this.files);
  @override
  List<CrossFile> init() => List.unmodifiable(files);
}

class _Discovery extends NearbyDevicesService {
  final Device device;
  _Discovery(this.device, IsolateController controller)
    : super(isolateController: controller, favoriteService: FavoritesService(MockPersistenceService()), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {device.fingerprint: device}, signalingDevices: {});
}

/// An independent HTTP peer that implements only original LocalSend v2 fields.
/// It knows nothing about the integration API, queue IDs or source references.
class _OriginalPeer {
  final HttpServer server;
  final paths = <String>[];
  final received = <String, List<int>>{};
  final failures = <Object>[];
  final sessions = <String, Map<String, dynamic>>{};
  int prepares = 0, uploads = 0;
  Set<String> expectedNames = {'folder/中文.bin', 'second.bin'};
  final failNames = <String>{};
  final receivedCounts = <String, int>{};
  bool declineNext = true, checksumRetry = true, holdNext = false;
  String? holdUploadName;
  Completer<void>? uploadHeld, uploadRelease;
  Completer<void>? held;
  Completer<void>? release;
  _OriginalPeer(this.server) {
    server.listen((request) {
      unawaited(handle(request));
    });
  }
  static Future<_OriginalPeer> start() async => _OriginalPeer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> handle(HttpRequest request) async {
    try {
      paths.add(request.uri.path);
      expect(request.method, 'POST');
      if (request.uri.path == '/api/localsend/v2/prepare-upload') {
        prepares++;
        final payload = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        expect(payload.keys.toSet(), {'info', 'files'});
        expect(payload['info']['protocol'], 'http');
        final files = payload['files'] as Map<String, dynamic>;
        expect(files.values.map((f) => f['fileName']).toSet(), expectedNames);
        expect(jsonEncode(payload), isNot(contains('selectionVersion')));
        if (declineNext) {
          declineNext = false;
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        if (holdNext) {
          holdNext = false;
          held!.complete();
          await release!.future;
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        final id = const Uuid().v4();
        sessions[id] = files;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'sessionId': id,
            'files': {for (final id in files.keys) id: 'original-token-$id'},
          }),
        );
        await request.response.close();
        return;
      }
      if (request.uri.path == '/api/localsend/v2/upload') {
        uploads++;
        expect(request.uri.queryParameters.keys.toSet(), {'sessionId', 'fileId', 'token'});
        final q = request.uri.queryParameters, id = q['fileId']!;
        expect(q['token'], 'original-token-$id');
        final metadata = sessions[q['sessionId']]![id] as Map<String, dynamic>;
        final bytes = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        expect(bytes.length, metadata['size']);
        expect(sha256.convert(bytes).toString(), metadata['sha256']);
        if (holdUploadName == metadata['fileName']) {
          holdUploadName = null;
          uploadHeld!.complete();
          await uploadRelease!.future;
          request.response.statusCode = 500;
        } else if (failNames.contains(metadata['fileName'])) {
          request.response.statusCode = 500;
        } else if (checksumRetry) {
          checksumRetry = false;
          request.response.statusCode = 422;
        } else {
          final name = metadata['fileName'] as String;
          received[name] = bytes;
          receivedCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
        }
        await request.response.close();
        return;
      }
      if (request.uri.path == '/api/localsend/v2/cancel') {
        if (uploadRelease != null && !uploadRelease!.isCompleted) uploadRelease!.complete();
        await request.drain<void>();
        await request.response.close();
        return;
      }
      throw StateError('Unexpected original peer route');
    } catch (error) {
      failures.add(error);
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (release != null && !release!.isCompleted) release!.complete();
    if (uploadRelease != null && !uploadRelease!.isCompleted) uploadRelease!.complete();
    await server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('workspace source API captures versioned files and sends original v2 bytes without changing selection', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-transfer-api-wire-');
    final peer = await _OriginalPeer.start();
    peer.checksumRetry = false;
    peer.declineNext = false;
    peer.expectedNames = {'private-source.bin'};
    final bytes = utf8.encode('original bytes\u0000中文\n');
    final source = File('${temp.path}/private-source.bin');
    await source.writeAsBytes(bytes);
    final files = [
      CrossFile(
        name: 'folder/中文.bin',
        fileType: FileType.other,
        size: bytes.length,
        thumbnail: null,
        asset: null,
        path: source.path,
        bytes: null,
        lastModified: null,
        lastAccessed: null,
      ),
      CrossFile(
        name: 'second.bin',
        fileType: FileType.other,
        size: 3,
        thumbnail: null,
        asset: null,
        path: null,
        bytes: [1, 2, 3],
        lastModified: null,
        lastAccessed: null,
      ),
    ];
    final security = await generateSecurityContext();
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: security,
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Wire fixture', androidSdkInt: null),
      alias: 'Wire fixture',
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
    final serverConnector =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpServerEvent>, SendToIsolateData<IsolateTask<BaseHttpServerTask>>, InitialData>(
          task: setupHttpServerIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final uploadConnector =
        await TypedIsolates.startIsolate<IsolateTaskStreamResult<HttpUploadEvent>, SendToIsolateData<IsolateTask<BaseHttpUploadTask>>, InitialData>(
          task: setupHttpUploadIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final persistence = MockPersistenceService();
    when(persistence.getCreateChecksums()).thenReturn(true);
    when(persistence.getSecurityContext()).thenReturn(security);
    final device = Device.empty.copyWith(
      ip: '127.0.0.1',
      port: peer.server.port,
      https: false,
      fingerprint: 'A' * 64,
      alias: 'Original wire peer',
      version: '2.2',
      channels: [HttpChannel(host: '127.0.0.1', port: peer.server.port, https: false)],
    );
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        sendRecoveryStoreProvider.overrideWithValue(SendRecoveryStore(Directory('${temp.path}/journal'))),
        deviceFullInfoProvider.overrideWithBuilder((_) => device.copyWith(alias: 'Sender', fingerprint: security.certificateHash)),
        nearbyDevicesProvider.overrideWithNotifier((ref) => _Discovery(device, ref.notifier(parentIsolateProvider))),
        selectedSendingFilesProvider.overrideWithNotifier((_) => _Selection(files)),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: uploadConnector, httpServer: serverConnector),
          ),
        ),
      ],
    );
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '${h}h ${m}m',
      ),
    );
    final client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
    final server = container.notifier(serverProvider);
    try {
      final started = await server.startServer(alias: 'Wire fixture', port: 0, https: false).timeout(const Duration(seconds: 15));
      expect(started, isNotNull);
      Future<(Map<String, dynamic>, String)> key() async {
        final draft = await createIntegrationApiKeyDraft(
          name: 'Wire API',
          grant: jsonEncode({
            'scopes': ['service.read', 'files.read', 'devices.read', 'transfers.read', 'transfers.send', 'transfers.control'],
            'workspaces': ['*'],
          }),
        );
        final record = jsonDecode(await draft.persistenceRecord()) as Map<String, dynamic>;
        final token = (await draft.takeSecret())!;
        draft.dispose();
        return (record, token);
      }

      final (record, token) = await key();
      final (otherRecord, otherToken) = await key();
      await server.integrationApiControl(
        expectedGeneration: server.generation,
        configuration: jsonEncode({
          'revision': 1,
          'enabled': true,
          'authRequired': true,
          'keys': [record, otherRecord],
          'globalLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
          'keyLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 8},
          'anonymousLimits': {'perSecond': 10, 'perMinute': 600, 'concurrent': 2},
          'anonymousGrant': {'scopes': [], 'workspaces': []},
          'allowedOrigins': [],
        }),
      );
      Future<(int, Map<String, dynamic>)> call(String path, {Object? body, bool post = false, String? credential}) async {
        final req = await client.openUrl(post ? 'POST' : 'GET', Uri.parse('http://127.0.0.1:${started!.port}/api/legnasend/v1/integration$path'));
        req.headers.set('authorization', 'Bearer ${credential ?? token}');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.add(utf8.encode(jsonEncode(body)));
        } else if (post) {
          req.contentLength = 0;
        }
        final response = await req.close();
        final result = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
        expect(jsonEncode(result), isNot(contains(temp.path)));
        expect(jsonEncode(result), isNot(contains(token)));
        return (response.statusCode, result);
      }

      final workspaceId = const Uuid().v4();
      await server.configureDirectoryWorkspaces(
        expectedGeneration: server.generation,
        config: jsonEncode({
          'revision': 1,
          'enabled': true,
          'workspaces': [
            {'id': workspaceId, 'name': 'Source', 'slug': 'source', 'root': temp.path, 'generation': 1, 'visible': true},
          ],
        }),
      );
      final fileId = base64Url.encode(utf8.encode('private-source.bin')).replaceAll('=', '');
      final head = await client.openUrl(
        'HEAD',
        Uri.parse('http://127.0.0.1:${started!.port}/api/legnasend/v1/integration/workspaces/$workspaceId/files/$fileId/content?generation=1'),
      );
      head.headers.set('authorization', 'Bearer $token');
      final metadata = await head.close();
      expect(metadata.statusCode, 200);
      final version = metadata.headers.value('etag')!;
      await metadata.drain<void>();
      final (_, status) = await call('/status');
      final (_, devices) = await call('/devices');
      final intent = {
        'instanceId': status['instanceId'],
        'generation': 1,
        'deviceId': devices['devices'][0]['id'],
        'requestId': const Uuid().v4(),
        'files': [
          {'id': fileId, 'version': version},
        ],
      };
      final (code, receipt) = await call('/workspaces/$workspaceId/send', post: true, body: intent);
      expect(code, 202, reason: jsonEncode(receipt));
      final taskId = receipt['task']['id'] as String;
      for (var i = 0; i < 500; i++) {
        final (_, task) = await call('/transfers/$taskId');
        if (task['task']['status'] == 'succeeded') break;
        if (task['task']['status'] == 'failed') fail(jsonEncode(task));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(peer.received['private-source.bin'], bytes);
      expect(peer.prepares, 1);
      final job = container.read(sendQueueProvider).single;
      expect(job.files.single.path, isNot(source.path));
      await source.writeAsString('changed source after accepted');
      expect(await File(job.files.single.path!).readAsBytes(), bytes);
      expect(container.read(selectedSendingFilesProvider), files);
      final (replayCode, replayed) = await call('/workspaces/$workspaceId/send', post: true, body: intent);
      expect(replayCode, 202);
      expect(replayed['task']['id'], taskId);
      expect(peer.prepares, 1);
      final (stale, _) = await call(
        '/workspaces/$workspaceId/send',
        post: true,
        body: {...intent, 'instanceId': const Uuid().v4(), 'requestId': const Uuid().v4()},
      );
      expect(stale, 409);
      final (changed, _) = await call('/workspaces/$workspaceId/send', post: true, body: {...intent, 'requestId': const Uuid().v4()});
      expect(changed, 503);
      expect(peer.prepares, 1);
      final (foreign, _) = await call('/transfers/$taskId', credential: otherToken);
      expect(foreign, 404);
      expect(peer.failures, isEmpty);
    } finally {
      for (final job in container.read(sendQueueProvider)) {
        if (!job.terminal) await container.notifier(sendQueueProvider).cancel(job.id);
      }
      await peer.close();
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer();
      serverConnector.isolate.kill();
      uploadConnector.isolate.kill();
      final queue = container.notifier(sendQueueProvider);
      container.disposeContainer();
      await queue.recoveryClosed;
      await temp.delete(recursive: true);
    }
  });
}
