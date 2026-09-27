@Timeout(Duration(minutes: 3))
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
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/send_session_lookup.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
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
  test('actual API host and native send queue preserve original v2 bytes retry and cancellation', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-transfer-api-wire-');
    final peer = await _OriginalPeer.start();
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
            'scopes': ['devices.read', 'transfers.read', 'transfers.send', 'transfers.control', 'nativeTasks.read', 'nativeTasks.control'],
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

      final (ds, devices) = await call('/devices');
      expect(ds, 200);
      final deviceId = devices['devices'][0]['id'];
      final (ss, selection) = await call('/send-selection');
      expect(ss, 200);
      final intent = {'deviceId': deviceId, 'selectionVersion': selection['selectionVersion'], 'requestId': const Uuid().v4()};
      final (sent, accepted) = await call('/transfers/send', post: true, body: intent);
      expect(sent, 202);
      final first = accepted['task']['id'] as String;
      Future<Map<String, dynamic>> terminal(String id) async => await (() async {
        for (var i = 0; i < 400; i++) {
          final (status, data) = await call('/transfers/$id');
          expect(status, 200);
          final task = data['task'] as Map<String, dynamic>;
          if (['succeeded', 'failed', 'canceled'].contains(task['status'])) return task;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        throw TimeoutException('Native transfer did not finish');
      })().timeout(const Duration(seconds: 20));
      expect((await terminal(first))['status'], 'failed');
      expect(peer.prepares, 1);
      final (_, duplicate) = await call('/transfers/send', post: true, body: intent);
      expect(duplicate['task']['id'], first);
      expect(peer.prepares, 1);
      final (foreign, _) = await call('/transfers/$first', credential: otherToken);
      expect(foreign, 404);
      final retry = {'requestId': const Uuid().v4()};
      final (retried, next) = await call('/transfers/$first/retry', post: true, body: retry);
      expect(retried, 202);
      final second = next['task']['id'] as String;
      expect(second, isNot(first));
      final finished = await terminal(second);
      expect(finished['status'], 'succeeded');
      expect(finished['transferredBytes'], bytes.length + 3);
      expect(finished['totalBytes'], bytes.length + 3);
      expect(finished['bytesPerSecond'], 0);
      expect(peer.received['folder/中文.bin'], bytes);
      expect(peer.received['second.bin'], [1, 2, 3]);
      expect(peer.prepares, 2);
      expect(peer.uploads, 3);
      final (_, sameRetry) = await call('/transfers/$first/retry', post: true, body: retry);
      expect(sameRetry['task']['id'], second);
      expect(peer.prepares, 2);
      // The UI queue retry is remaining-files recovery, while the published
      // integration API deliberately retains its separate whole-batch contract.
      final queue = container.notifier(sendQueueProvider);
      Future<SendJob> queueTerminal(String id) async {
        for (var i = 0; i < 400; i++) {
          final job = container.read(sendQueueProvider).firstWhere((job) => job.id == id);
          if (job.terminal) return job;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        throw TimeoutException(
          'Native recovery $id did not finish: jobs=${container.read(sendQueueProvider).map((j) => '${j.id}:${j.status}').toList()}, sessions=${container.read(sendProvider).map((id, s) => MapEntry(id, '${s.status}/${s.sendingTasks?.length}'))}, peer=${peer.failures}, prepares=${peer.prepares}, uploads=${peer.uploads}',
        );
      }

      final successesBefore = peer.receivedCounts['folder/中文.bin']!;
      peer.failNames.add('second.bin');
      final partialId = queue.enqueueExplicit(device, files, device.channels.whereType<HttpChannel>().single);
      final partial = await queueTerminal(partialId);
      expect(partial.status, SendJobStatus.failed);
      expect(peer.receivedCounts['folder/中文.bin'], successesBefore + 1);
      peer.failNames.clear();
      peer.expectedNames = {'second.bin'};
      queue.retry(partial);
      final recovery = container.read(sendQueueProvider).last;
      expect(recovery.id, isNot(partialId));
      expect(recovery.files.map((f) => f.name), ['second.bin']);
      expect((await queueTerminal(recovery.id)).status, SendJobStatus.succeeded);
      expect(peer.receivedCounts['folder/中文.bin'], successesBefore + 1);
      expect(peer.received['second.bin'], [1, 2, 3]);
      expect(sha256.convert(peer.received['second.bin']!).toString(), sha256.convert([1, 2, 3]).toString());
      final jobsAfterSuccess = container.read(sendQueueProvider).length;
      queue.retry(await queueTerminal(recovery.id));
      expect(container.read(sendQueueProvider).length, jobsAfterSuccess);
      queue.remove(partial.id);
      queue.retry(partial); // A stale card must not resurrect a removed attempt.
      expect(container.read(sendQueueProvider).length, jobsAfterSuccess - 1);
      peer.expectedNames = {'folder/中文.bin', 'second.bin'};
      // Cancel an actual partly successful upload, then immediately retry.
      // Device FIFO must drain the old Rust task before starting the next one.
      peer.holdUploadName = 'second.bin';
      peer.uploadHeld = Completer<void>();
      peer.uploadRelease = Completer<void>();
      final interruptedId = queue.enqueueExplicit(device, files, device.channels.whereType<HttpChannel>().single);
      await peer.uploadHeld!.future.timeout(const Duration(seconds: 10));
      final interruptedSession = container.read(sendProvider)[interruptedId]!;
      final firstFileId = interruptedSession.files.values.firstWhere((f) => f.file.fileName == 'folder/中文.bin').file.id;
      for (
        var i = 0;
        i < 400 && container.read(fileTransferProvider).getStatus(sessionId: interruptedId, fileId: firstFileId) != FileStatus.finished;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(container.read(fileTransferProvider).getStatus(sessionId: interruptedId, fileId: firstFileId), FileStatus.finished);
      final beforeCancelCount = peer.receivedCounts['folder/中文.bin'];
      // Global task authority can address this locally enqueued task even though
      // it was never created through this or any other API key.
      final (nativeStatus, nativeList) = await call('/native-tasks', credential: otherToken);
      expect(nativeStatus, 200);
      final nativeTask = (nativeList['tasks'] as List).singleWhere((t) => t['direction'] == 'send' && t['phase'] == 'transferring') as Map;
      expect(nativeTask['transferredBytes'], greaterThanOrEqualTo(bytes.length));
      expect(nativeTask['bytesPerSecond'], isNonNegative);
      expect(jsonEncode(nativeTask), isNot(contains('folder/')));
      final cancelBody = {'epoch': nativeList['epoch'], 'version': nativeTask['version'], 'action': 'cancel'};
      final (cancelStatus, dispatched) = await call(
        '/native-tasks/${nativeTask['id']}/control',
        credential: otherToken,
        post: true,
        body: cancelBody,
      );
      expect(cancelStatus, 200);
      expect(dispatched['dispatched'], true);
      expect((await call('/native-tasks/${nativeTask['id']}/control', credential: otherToken, post: true, body: cancelBody)).$1, 409);
      final canceledSession = container.read(sendProvider)[interruptedId]!;
      expect(canceledSession.status, SessionStatus.canceledBySender);
      expect(isActiveSendSession(canceledSession), isFalse);
      // Freeze bytes at cancellation, including bytes already sent for the
      // interrupted file. A late worker error must not erase that progress.
      final bytesAtCancel = collectTransferActivities(
        jobs: container.read(sendQueueProvider),
        sends: container.read(sendProvider),
        receive: null,
        progress: container.read(fileTransferProvider),
      ).firstWhere((task) => task.id == interruptedId).transferredBytes;
      expect(bytesAtCancel, greaterThanOrEqualTo(bytes.length));
      peer.expectedNames = {'second.bin'};
      queue.retry(container.read(sendQueueProvider).firstWhere((job) => job.id == interruptedId));
      final resumedId = container.read(sendQueueProvider).last.id;
      expect((await queueTerminal(resumedId)).status, SendJobStatus.succeeded);
      expect(container.read(sendProvider)[interruptedId]!.sendingTasks, isEmpty);
      expect(peer.receivedCounts['folder/中文.bin'], beforeCancelCount);
      final canceledActivity = collectTransferActivities(
        jobs: container.read(sendQueueProvider),
        sends: container.read(sendProvider),
        receive: null,
        progress: container.read(fileTransferProvider),
      ).firstWhere((task) => task.id == interruptedId);
      expect(canceledActivity.transferredBytes, bytesAtCancel);
      expect(canceledActivity.active, isFalse);
      final (_, completedNative) = await call('/native-tasks', credential: otherToken);
      final oldNative = (completedNative['tasks'] as List).singleWhere((t) => t['id'] == nativeTask['id']) as Map;
      expect(oldNative['phase'], 'canceled');
      expect(oldNative['bytesPerSecond'], 0);
      expect(
        (await call(
          '/native-tasks/${oldNative['id']}/control',
          credential: otherToken,
          post: true,
          body: {'epoch': completedNative['epoch'], 'version': oldNative['version'], 'action': 'remove'},
        )).$1,
        200,
      );
      expect(container.read(sendProvider).containsKey(interruptedId), isFalse);
      expect(container.read(fileTransferProvider).getStatuses(interruptedId), isEmpty);
      peer.expectedNames = {'folder/中文.bin', 'second.bin'};
      // API retries remain explicitly whole-batch, including successful files.
      peer.failNames.add('second.bin');
      final (_, apiPartial) = await call('/transfers/send', post: true, body: {...intent, 'requestId': const Uuid().v4()});
      final apiPartialId = apiPartial['task']['id'] as String;
      expect((await terminal(apiPartialId))['status'], 'failed');
      final apiSuccessCount = peer.receivedCounts['folder/中文.bin']!;
      peer.failNames.clear();
      final (apiRetryStatus, apiRetryResult) = await call('/transfers/$apiPartialId/retry', post: true, body: {'requestId': const Uuid().v4()});
      expect(apiRetryStatus, 202);
      expect((await terminal(apiRetryResult['task']['id'] as String))['status'], 'succeeded');
      expect(peer.receivedCounts['folder/中文.bin'], apiSuccessCount + 1);
      // A withdrawn local source is still an explicit failure, never silently
      // treated as finished. Restoring it allows the same task history to retry.
      peer.expectedNames = {'folder/中文.bin'};
      await source.delete();
      final missingId = queue.enqueueExplicit(device, [files.first], device.channels.whereType<HttpChannel>().single);
      final missing = await queueTerminal(missingId);
      expect(missing.status, SendJobStatus.failed);
      expect(container.read(sendProvider)[missingId]!.files.values.single.errorMessage, isNotNull);
      await source.writeAsBytes(bytes);
      queue.retry(missing);
      final restored = container.read(sendQueueProvider).last;
      expect((await queueTerminal(restored.id)).status, SendJobStatus.succeeded);
      expect(peer.received['folder/中文.bin'], bytes);
      peer.expectedNames = {'folder/中文.bin', 'second.bin'};
      peer.holdNext = true;
      peer.held = Completer<void>();
      peer.release = Completer<void>();
      final (_, pending) = await call('/transfers/send', post: true, body: {...intent, 'requestId': const Uuid().v4()});
      final pendingId = pending['task']['id'] as String;
      await peer.held!.future.timeout(const Duration(seconds: 10));
      final (canceled, _) = await call('/transfers/$pendingId/cancel', post: true);
      expect(canceled, 200);
      expect((await terminal(pendingId))['status'], 'canceled');
      peer.release!.complete();
      final (removed, _) = await call('/transfers/$second/remove', post: true);
      expect(removed, 200);
      final (gone, _) = await call('/transfers/$second');
      expect(gone, 404);
      expect(peer.failures, isEmpty);
      expect(peer.paths.every((p) => p.startsWith('/api/localsend/v2/')), true);
      expect(await source.readAsBytes(), bytes);
    } finally {
      for (final job in container.read(sendQueueProvider)) {
        if (!job.terminal) await container.notifier(sendQueueProvider).cancel(job.id);
      }
      await peer.close();
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer().timeout(const Duration(seconds: 10));
      serverConnector.isolate.kill();
      uploadConnector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
