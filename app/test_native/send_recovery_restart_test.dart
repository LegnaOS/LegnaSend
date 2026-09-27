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
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/child/upload_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

/// Only discovery and local settings are supplied by the fixture. Sending uses
/// the production queue, SendNotifier, child isolates and Rust HTTP client.
class _Discovery extends NearbyDevicesService {
  final Device? initial;
  _Discovery(this.initial, IsolateController controller, FavoritesService favorites)
    : super(isolateController: controller, favoriteService: favorites, discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() => NearbyDevicesState(
    runningFavoriteScan: false,
    runningIps: {},
    devices: initial == null ? {} : {initial!.fingerprint: initial!},
    signalingDevices: {},
  );
}

class _RealHttp extends HttpOverrides {}

/// Independent original-v2 peer; no recovery identifiers or private endpoints.
class _Peer {
  final HttpServer server;
  final errors = <Object>[];
  final paths = <String>[];
  final batches = <Set<String>>[];
  final received = <String, List<int>>{};
  final counts = <String, int>{};
  final sessions = <String, Map<String, dynamic>>{};
  final invalidTokens = <(String, String)>{};
  bool failSecond = true;
  _Peer(this.server) {
    server.listen((request) => unawaited(_handle(request)));
  }
  static Future<_Peer> start() async => _Peer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> _handle(HttpRequest request) async {
    try {
      paths.add(request.uri.path);
      expect(request.method, 'POST');
      if (request.uri.path == '/api/localsend/v2/prepare-upload') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        expect(body.keys.toSet(), {'info', 'files'});
        final files = body['files'] as Map<String, dynamic>;
        batches.add(files.values.map((f) => f['fileName'] as String).toSet());
        final id = const Uuid().v4();
        sessions[id] = files;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'sessionId': id,
            'files': {for (final id in files.keys) id: 'token-$id'},
          }),
        );
      } else if (request.uri.path == '/api/localsend/v2/upload') {
        final q = request.uri.queryParameters;
        expect(q.keys.toSet(), {'sessionId', 'fileId', 'token'});
        expect(q['token'], 'token-${q['fileId']}');
        if (invalidTokens.contains((q['sessionId']!, q['fileId']!))) {
          await request.drain<void>();
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        final metadata = sessions[q['sessionId']]![q['fileId']] as Map<String, dynamic>;
        final bytes = await request.fold<List<int>>([], (all, bytes) => all..addAll(bytes));
        expect(bytes.length, metadata['size']);
        expect(sha256.convert(bytes).toString(), metadata['sha256']);
        final name = metadata['fileName'] as String;
        if (name == 'folder/第二个.bin' && failSecond) {
          request.response.statusCode = 500;
          invalidTokens.add((q['sessionId']!, q['fileId']!));
        } else {
          received[name] = bytes;
          counts.update(name, (n) => n + 1, ifAbsent: () => 1);
        }
      } else if (request.uri.path == '/api/localsend/v2/cancel') {
        await request.drain<void>();
      } else {
        throw StateError('Unexpected original peer route ${request.uri}');
      }
      await request.response.close();
    } catch (error) {
      errors.add(error);
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }
}

class _Host {
  final RefenaContainer container;
  final Future<void> Function() close;
  _Host(this.container, this.close);
  SendQueueNotifier get queue => container.notifier(sendQueueProvider);
  SendJob job(String id) => container.read(sendQueueProvider).firstWhere((j) => j.id == id);
  Future<SendJob> terminal(String id) async {
    for (var n = 0; n < 600; n++) {
      final value = job(id);
      if (value.terminal) return value;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('Original-v2 send did not finish: ${job(id).status}');
  }

  static Future<_Host> boot(Directory recovery, Device peer, {required bool discovered}) async {
    final security = await generateSecurityContext();
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: security,
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Recovery fixture', androidSdkInt: null),
      alias: 'Recovery sender',
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
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        sendRecoveryStoreProvider.overrideWithValue(SendRecoveryStore(recovery)),
        deviceFullInfoProvider.overrideWithBuilder((_) => peer.copyWith(alias: 'Recovery sender', fingerprint: security.certificateHash)),
        nearbyDevicesProvider.overrideWithNotifier(
          (ref) => _Discovery(discovered ? peer : null, ref.notifier(parentIsolateProvider), ref.notifier(favoritesProvider)),
        ),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(
              syncState: sync,
              discovery: null,
              httpUpload: uploadConnector,
              httpServer: serverConnector,
            ),
          ),
        ),
      ],
    );
    final server = container.notifier(serverProvider);
    await server.startServer(alias: 'Recovery sender', port: 0, https: false).timeout(const Duration(seconds: 15));
    await container.notifier(sendQueueProvider).initializeRecovery();
    return _Host(container, () async {
      final queue = container.notifier(sendQueueProvider);
      for (final job in container.read(sendQueueProvider)) {
        if (!job.terminal) await container.notifier(sendQueueProvider).cancel(job.id);
      }
      await container.notifier(sendQueueProvider).flushRecovery();
      if (container.read(serverProvider) != null) await server.stopServer().timeout(const Duration(seconds: 10));
      serverConnector.isolate.kill();
      uploadConnector.isolate.kill();
      container.disposeContainer();
      await queue.recoveryClosed;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeWorkspaceNativeBridge(Directory.current.parent.path));
  test('manual failed-file queue retry replaces invalid wire tokens and owns only the selected source', () async {
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '$h:$m',
      ),
    );
    final temp = await Directory.systemTemp.createTemp('single-retry-wire-');
    final peer = await _Peer.start();
    final device = Device.empty.copyWith(
      ip: '127.0.0.1',
      port: peer.server.port,
      https: false,
      fingerprint: 'A' * 64,
      alias: 'Original v2 receiver',
      version: '2.2',
      channels: [HttpChannel(host: '127.0.0.1', port: peer.server.port, https: false)],
    );
    final bytes = List<int>.generate(96 * 1024, (i) => i % 251);
    CrossFile source(String name, List<int> bytes) => CrossFile(
      name: name,
      fileType: FileType.other,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );
    _Host? host;
    final http = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp());
    try {
      host = await _Host.boot(Directory('${temp.path}/recovery'), device, discovered: true);
      final originalId = host.queue.enqueueExplicit(device, [
        source('first.bin', [1, 2, 3]),
        source('folder/第二个.bin', bytes),
      ], device.channels.whereType<HttpChannel>().single);
      expect((await host.terminal(originalId)).status, SendJobStatus.failed);
      final original = host.container.read(sendProvider)[originalId]!;
      final failed = original.files.values.singleWhere((file) => file.file.fileName == 'folder/第二个.bin');
      final complete = original.files.values.singleWhere((file) => file.file.fileName == 'first.bin');
      final oldTokenUri = Uri.parse('http://127.0.0.1:${peer.server.port}/api/localsend/v2/upload').replace(
        queryParameters: {
          'sessionId': original.remoteSessionId!,
          'fileId': failed.file.id,
          'token': failed.token!,
        },
      );
      final stale = await http.postUrl(oldTokenUri);
      stale.add(bytes);
      final rejected = await stale.close();
      expect(rejected.statusCode, 403, reason: 'The old manual-retry token really is invalid on the peer');
      await rejected.drain<void>();

      peer.failSecond = false;
      final nextId = host.queue.retryFile(sessionId: originalId, file: failed)!;
      expect(
        host.queue.retryFile(sessionId: originalId, file: failed),
        nextId,
        reason: 'Rapid duplicate click must reuse the new task',
      );
      expect(nextId, isNot(originalId));
      expect(host.job(nextId).files.single.name, failed.file.fileName);
      expect(host.container.read(sendProvider)[originalId], same(original));
      expect(host.container.read(fileTransferProvider).getStatus(sessionId: originalId, fileId: complete.file.id), FileStatus.finished);
      expect((await host.terminal(nextId)).status, SendJobStatus.succeeded);
      final next = host.container.read(sendProvider)[nextId]!;
      expect(next.remoteSessionId, isNot(original.remoteSessionId));
      expect(next.files.values.single.token, isNot(failed.token));
      expect(peer.batches, [
        {'first.bin', 'folder/第二个.bin'},
        {'folder/第二个.bin'},
      ]);
      expect(peer.counts['first.bin'], 1);
      expect(peer.counts['folder/第二个.bin'], 1);
      expect(peer.received['folder/第二个.bin'], bytes);
      final digest = sha256.convert(peer.received['folder/第二个.bin']!).toString();
      expect(digest, sha256.convert(bytes).toString());
      final newOwnedPath = host.job(nextId).files.single.path!;
      expect(newOwnedPath, isNot(failed.path));
      await host.queue.removeAndWait(originalId);
      expect(host.container.read(sendQueueProvider).any((job) => job.id == originalId), false);
      expect(await File(newOwnedPath).readAsBytes(), bytes, reason: 'New task owns its source independently of old history');
      expect(peer.errors, isEmpty);
      final evidence = Directory('${Directory.current.parent.path}/build/test-results/batch29/single-retry')..createSync(recursive: true);
      await File('${evidence.path}/wire.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'transport': 'real native Rust client and upload isolate, independent original-v2 HTTP fixture',
          'oldUploadStatus': 500,
          'staleTokenStatus': rejected.statusCode,
          'prepareBatches': peer.batches.map((batch) => batch.toList()).toList(),
          'newRemoteSession': next.remoteSessionId != original.remoteSessionId,
          'newFileToken': next.files.values.single.token != failed.token,
          'savedCounts': peer.counts,
          'sha256': digest,
          'bytes': bytes.length,
          'independentOwnedSourceAfterOriginalHistoryRemoval': true,
          'originalApplicationPeerAcceptance': false,
        }),
      );
    } finally {
      http.close(force: true);
      await host?.close();
      await peer.server.close(force: true);
      await temp.delete(recursive: true);
    }
  });

  test('fresh native host restores confirmed files, gates source and peer, and retries only unfinished original-v2 bytes', () async {
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '${h}h ${m}m',
      ),
    );
    final temp = await Directory.systemTemp.createTemp('legnasend-send-restart-');
    final recovery = Directory('${temp.path}/recovery');
    final first = File('${temp.path}/first.bin');
    final second = File('${temp.path}/second.bin');
    final firstBytes = utf8.encode('confirmed once\u0000中文\n');
    final secondBytes = List<int>.generate(96 * 1024, (i) => i % 251);
    await first.writeAsBytes(firstBytes);
    await second.writeAsBytes(secondBytes);
    // Use a round-trippable timestamp: this host API writes whole seconds while
    // FileStat may expose subsecond values from a freshly written file.
    await second.setLastModified(DateTime.now());
    final originalModified = (await second.stat()).modified;
    CrossFile source(File file, String name, int size) => CrossFile(
      name: name,
      fileType: FileType.other,
      size: size,
      thumbnail: null,
      asset: null,
      path: file.path,
      bytes: null,
      lastModified: null,
      lastAccessed: null,
    );
    final files = [source(first, 'first.bin', firstBytes.length), source(second, 'folder/第二个.bin', secondBytes.length)];
    final peer = await _Peer.start();
    final device = Device.empty.copyWith(
      ip: '127.0.0.1',
      port: peer.server.port,
      https: false,
      fingerprint: 'A' * 64,
      alias: 'Original v2 receiver',
      version: '2.2',
      channels: [HttpChannel(host: '127.0.0.1', port: peer.server.port, https: false)],
    );
    _Host? active;
    try {
      var host = active = await _Host.boot(recovery, device, discovered: true);
      final id = host.queue.enqueueExplicit(device, files, device.channels.whereType<HttpChannel>().single);
      expect((await host.terminal(id)).status, SendJobStatus.failed);
      expect(peer.received['first.bin'], firstBytes);
      expect(peer.counts['first.bin'], 1);
      expect(peer.received.containsKey('folder/第二个.bin'), false);
      final discardId = host.queue.enqueueExplicit(device, [files.last], device.channels.whereType<HttpChannel>().single);
      expect((await host.terminal(discardId)).status, SendJobStatus.failed);
      await host.queue.flushRecovery();
      // This destroys the actual old container and worker isolates, then opens a
      // fresh store/host. It is restart reconstruction, not an OS force-kill test.
      await host.close();
      active = null;
      final requestsBeforeRestart = peer.paths.length;
      host = active = await _Host.boot(recovery, device, discovered: false);
      final restored = host.job(id);
      expect(restored.restored, true);
      expect(restored.completedIndices, {0});
      expect(restored.skippedIndices, isEmpty);
      expect(host.container.read(sendProvider), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(peer.paths.length, requestsBeforeRestart, reason: 'Restoring history must never auto-send');
      expect(await host.queue.resumeRecovered(host.job(id)), false);
      expect(host.job(id).recoveryIssue, isNotNull);
      expect(peer.paths.length, requestsBeforeRestart, reason: 'Persisted address is not proof of rediscovery');
      await host.container.redux(nearbyDevicesProvider).dispatchAsync(RegisterDeviceAction(device.copyWith(fingerprint: 'B' * 64)));
      expect(await host.queue.resumeRecovered(host.job(id)), false);
      expect(peer.paths.length, requestsBeforeRestart, reason: 'A different fingerprint at the old address is not the recipient');
      await host.container.redux(nearbyDevicesProvider).dispatchAsync(RegisterDeviceAction(device));
      await second.delete();
      expect(await host.queue.resumeRecovered(host.job(id)), false);
      expect(host.job(id).recoveryIssue, isNotNull);
      expect(peer.paths.length, requestsBeforeRestart, reason: 'Missing source is rejected before any network send');
      await second.writeAsBytes([...secondBytes, 123]);
      expect(await host.queue.resumeRecovered(host.job(id)), false);
      expect(peer.paths.length, requestsBeforeRestart, reason: 'Changed source is rejected before any network send');
      await second.writeAsBytes(secondBytes.map((byte) => byte ^ 0xff).toList());
      await second.setLastModified(originalModified.add(const Duration(seconds: 2)));
      expect(await host.queue.resumeRecovered(host.job(id)), false);
      expect(peer.paths.length, requestsBeforeRestart, reason: 'Same-size source changes are also rejected by their metadata');
      await second.writeAsBytes(secondBytes);
      await second.setLastModified(originalModified);
      peer.failSecond = false;
      expect(
        await host.queue.resumeRecovered(host.job(id)),
        true,
        reason: '${host.job(id).recoveryIssue}; original=$originalModified restored=${(await second.stat()).modified}',
      );
      final next = host.job(id);
      expect(next.files.map((file) => file.name), ['first.bin', 'folder/第二个.bin']);
      expect((await host.terminal(id)).status, SendJobStatus.succeeded);
      expect(host.job(id).completedIndices, {0, 1});
      expect(host.container.read(sendProvider)[id]!.files.values.map((file) => file.file.fileName), ['folder/第二个.bin']);
      expect(peer.batches, [
        {'first.bin', 'folder/第二个.bin'},
        {'folder/第二个.bin'},
        {'folder/第二个.bin'},
      ]);
      expect(peer.counts['first.bin'], 1, reason: 'The successful file must not be duplicated after restart');
      expect(peer.counts['folder/第二个.bin'], 1);
      expect(peer.received['folder/第二个.bin'], secondBytes);
      expect(sha256.convert(peer.received['folder/第二个.bin']!), sha256.convert(secondBytes));
      host.queue.remove(discardId);
      for (var i = 0; i < 200 && host.container.read(sendQueueProvider).any((job) => job.id == discardId); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await host.queue.flushRecovery();
      expect(host.container.read(sendQueueProvider).any((j) => j.id == discardId), false);
      expect(await first.readAsBytes(), firstBytes);
      expect(await second.readAsBytes(), secondBytes);
      await host.close();
      active = null;
      final finalRequests = peer.paths.length;
      host = active = await _Host.boot(recovery, device, discovered: true);
      expect(
        host.container.read(sendQueueProvider).any((j) => j.id == discardId),
        false,
        reason: 'Deleted recovery card stays deleted after another restart',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(peer.paths.length, finalRequests);
      expect(peer.paths.every((path) => path.startsWith('/api/localsend/v2/')), true);
      expect(peer.errors, isEmpty);
    } finally {
      if (active != null) await active.close();
      await peer.server.close(force: true);
      await temp.delete(recursive: true);
    }
  });
}
