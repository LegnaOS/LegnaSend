@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart' as native;
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('workspace activity crosses Rust, child isolate, polling, directions, speed and scoped cancellation', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('workspace-activity-wire-');
    await native.configureReceiveCacheRegistry(directory: temp.path);
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
    final persistence = MockPersistenceService();
    when(persistence.getAlias()).thenReturn('Wire fixture');
    when(persistence.getSecurityContext()).thenReturn(security);
    final device = Device.empty.copyWith(alias: 'Wire fixture', fingerprint: security.certificateHash, version: '2.2');
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        deviceFullInfoProvider.overrideWithBuilder((_) => device),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: null, httpServer: serverConnector),
          ),
        ),
      ],
    );
    final client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
    final server = container.notifier(serverProvider);
    Socket? uploading;
    try {
      final rootDirectory = await Directory('${temp.path}/workspace').create();
      final bundle = await Directory('${rootDirectory.path}/bundle').create();
      const source = 'abcdefghijklmnop';
      await File('${bundle.path}/small.txt').writeAsString(source);
      final large = await File('${rootDirectory.path}/large.bin').open(mode: FileMode.write);
      await large.truncate(64 * 1024 * 1024);
      await large.close();
      final started = (await server.startServer(alias: 'Activity fixture', port: 0, https: false))!;
      const workspaceId = '11111111-1111-4111-8111-111111111111';
      const workspaceName = '并行工作区 Workspace';
      Future<void> configureWorkspace() async {
        await container
            .redux(parentIsolateProvider)
            .dispatchAsyncTakeResult(
              IsolateHttpServerDirectoryCatalogAction(
                jsonEncode({
                  'revision': 1,
                  'enabled': true,
                  'workspaces': [
                    {
                      'id': workspaceId,
                      'name': workspaceName,
                      'slug': 'activity',
                      'root': rootDirectory.path,
                      'generation': 1,
                      'visible': true,
                      'allowUpload': true,
                    },
                  ],
                }),
              ),
            );
      }

      await configureWorkspace();
      final root = 'http://127.0.0.1:${started.port}';
      const api = '/api/legnasend/v1/workspaces/$workspaceId';
      String fileUrl(String relative, {bool preview = false}) {
        final id = base64Url.encode(utf8.encode(relative)).replaceAll('=', '');
        return '$root$api/files/$id/content?generation=1${preview ? '&preview=1' : ''}';
      }

      Future<void> until(bool Function() done, String label) async {
        final end = DateTime.now().add(const Duration(seconds: 12));
        while (!done()) {
          if (DateTime.now().isAfter(end)) throw StateError('Missing workspace transition: $label');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      List<TransferActivity> tasks() => container.read(transferActivityProvider);
      Future<List<int>> bytes(HttpClientResponse response) => response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      container.read(transferSpeedProvider);
      final head = await (await client.headUrl(Uri.parse(fileUrl('bundle/small.txt')))).close();
      expect(head.statusCode, 200);
      await head.drain<void>();
      final preview = await (await client.getUrl(Uri.parse(fileUrl('bundle/small.txt', preview: true)))).close();
      expect(utf8.decode(await bytes(preview)), source);
      final emptySnapshot = await container.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerWebDownloadSnapshotAction());
      expect(jsonDecode(emptySnapshot), isEmpty, reason: 'Metadata and previews are not explicit transfers');
      final range = await client.getUrl(Uri.parse(fileUrl('bundle/small.txt')));
      range.headers.set(HttpHeaders.rangeHeader, 'bytes=3-7');
      final rangeResponse = await range.close();
      expect(rangeResponse.statusCode, 206);
      final rangeBytes = await bytes(rangeResponse);
      expect(utf8.decode(rangeBytes), 'defgh');
      await until(() => tasks().any((task) => task.phase == TransferPhase.succeeded), 'completed range');
      final ranged = tasks().single;
      expect(ranged.workspaceId, workspaceId);
      expect(ranged.workspaceName, workspaceName);
      expect(ranged.direction, TransferDirection.send);
      expect(ranged.operation, 'download');
      expect(ranged.totalBytes, 5);
      expect(ranged.transferredBytes, 5);
      final archiveResponse = await (await client.getUrl(Uri.parse('$root$api/archive?generation=1&path=bundle'))).close();
      expect(archiveResponse.statusCode, 200);
      final zip = await bytes(archiveResponse);
      expect(zip.take(2), [0x50, 0x4b]);
      await until(() => tasks().any((task) => task.operation == 'archive' && task.phase == TransferPhase.succeeded), 'one ZIP activity');
      expect(tasks().length, 2, reason: 'ZIP internals must not create per-file activity');
      final zipped = tasks().singleWhere((task) => task.operation == 'archive');
      expect(zipped.transferredBytes, zip.length);
      final downloading = await (await client.getUrl(Uri.parse(fileUrl('large.bin')))).close();
      await until(() => tasks().any((task) => task.direction == TransferDirection.send && task.active), 'active download');
      final download = tasks().singleWhere((task) => task.direction == TransferDirection.send && task.active);
      uploading = await Socket.connect('127.0.0.1', started.port);
      final uploadReply = uploading.fold<List<int>>([], (all, chunk) => all..addAll(chunk)).then<Object>((value) => value, onError: (Object e) => e);
      uploading.write(
        'POST $api/upload?generation=1&path=partial.bin HTTP/1.1\r\n'
        'Host: 127.0.0.1:${started.port}\r\nConnection: close\r\n'
        'Content-Type: application/octet-stream\r\nContent-Length: 1048576\r\nX-LegnaSend-Upload: 1\r\n\r\n',
      );
      uploading.add(Uint8List(65536));
      await uploading.flush();
      await until(() => tasks().any((task) => task.direction == TransferDirection.receive && task.transferredBytes >= 65536), 'actual written bytes');
      final upload = tasks().singleWhere((task) => task.direction == TransferDirection.receive && task.active);
      expect(upload.operation, 'upload');
      expect(upload.workspaceId, workspaceId);
      expect(upload.totalBytes, 1048576);
      expect(tasks().any((task) => task.id == download.id && task.active), true);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      uploading.add(Uint8List(65536));
      await uploading.flush();
      await until(() => (container.read(transferSpeedProvider)[upload.key] ?? 0) > 0, 'receive speed sampled from byte changes');
      final speed = container.read(transferSpeedProvider)[upload.key];
      expect(await container.notifier(webTransferActivityProvider).cancel(upload.id), true);
      await until(() => tasks().any((task) => task.id == upload.id && task.phase == TransferPhase.canceled), 'scoped upload cancellation');
      await uploadReply.timeout(const Duration(seconds: 10));
      expect(await File('${rootDirectory.path}/partial.bin').exists(), false);
      await until(() => !rootDirectory.listSync().any((entry) => entry.path.endsWith('.part')), 'owned staging cleanup');
      expect(tasks().any((task) => task.id == download.id && task.active), true, reason: 'Canceling receive must not stop concurrent send');
      expect(await container.notifier(webTransferActivityProvider).cancel(download.id), true);
      await expectLater(downloading.drain<void>(), throwsA(isA<HttpException>()));
      await until(() => tasks().any((task) => task.id == download.id && task.phase == TransferPhase.canceled), 'scoped download cancellation');
      final payload = utf8.encode('finished after cancellation 中文');
      final next = await client.postUrl(Uri.parse('$root$api/upload?generation=1&path=finished.txt'));
      next.headers.set('X-LegnaSend-Upload', '1');
      next.headers.contentType = ContentType.binary;
      next.contentLength = payload.length;
      next.add(payload);
      final saved = await next.close();
      expect(saved.statusCode, 201);
      await saved.drain<void>();
      await until(
        () => tasks().any((task) => task.direction == TransferDirection.receive && task.phase == TransferPhase.succeeded),
        'published upload',
      );
      expect(sha256.convert(await File('${rootDirectory.path}/finished.txt').readAsBytes()), sha256.convert(payload));
      final completedUpload = tasks().singleWhere((task) => task.direction == TransferDirection.receive && task.phase == TransferPhase.succeeded);
      expect(completedUpload.transferredBytes, payload.length);
      final info = await (await client.getUrl(Uri.parse('$root/api/localsend/v2/info'))).close();
      expect(info.statusCode, 200);
      await info.drain<void>();
      // Deterministically stop observation between the last progress sample and
      // publication. A listener stop must reconcile the saved outcome, not infer
      // cancellation from a stale active snapshot.
      uploading = await Socket.connect('127.0.0.1', started.port);
      final finalReply = uploading.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      uploading.write(
        'POST $api/upload?generation=1&path=unobserved.bin HTTP/1.1\r\n'
        'Host: 127.0.0.1:${started.port}\r\nConnection: close\r\n'
        'Content-Type: application/octet-stream\r\nContent-Length: 1048576\r\nX-LegnaSend-Upload: 1\r\n\r\n',
      );
      uploading.add(Uint8List(65536));
      await uploading.flush();
      await until(() => tasks().any((task) => task.direction == TransferDirection.receive && task.active), 'last observed active upload');
      final unobserved = tasks().singleWhere((task) => task.direction == TransferDirection.receive && task.active);
      container.notifier(webTransferActivityProvider).stopPolling();
      uploading.add(Uint8List(1048576 - 65536));
      await uploading.flush();
      expect(utf8.decode(await finalReply.timeout(const Duration(seconds: 10))), startsWith('HTTP/1.1 201'));
      expect(await File('${rootDirectory.path}/unobserved.bin').length(), 1048576);
      expect(tasks().singleWhere((task) => task.id == unobserved.id).active, true, reason: 'The final snapshot has not been observed');
      await server.stopServer();
      expect(
        container.read(webTransferActivityProvider).singleWhere((task) => task.id == unobserved.id).phase,
        TransferPhase.succeeded,
        reason: 'The final stop RPC commits the actual published outcome before returning',
      );
      // Refena view notifications are delivered asynchronously; require the
      // same authoritative success in the derived view, never relax its phase.
      await until(
        () => tasks().any((task) => task.id == unobserved.id && task.phase == TransferPhase.succeeded),
        'final stopped-listener publication',
      );
      expect(
        tasks().singleWhere((task) => task.id == unobserved.id).phase,
        TransferPhase.succeeded,
        reason: 'Core-confirmed publication must not be replaced by inferred cancellation',
      );
      // A stopped listener is still observable without a live HTTP service.
      // Restarting must preserve real outcomes, not allocate a chain of retired
      // listeners or forget IDs whose publication finished around shutdown.
      final stoppedSnapshot = await container.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerWebDownloadSnapshotAction());
      expect((jsonDecode(stoppedSnapshot) as List).any((dynamic task) => task['id'] == unobserved.id && task['phase'] == 'succeeded'), true);
      final preservedIds = tasks().map((task) => task.id).toSet();
      final restartEvidence = <Map<String, Object>>[];
      for (var cycle = 0; cycle < 4; cycle++) {
        final current = (await server.startServer(alias: 'Activity restart fixture', port: 0, https: false))!;
        await configureWorkspace();
        final request = await client.postUrl(Uri.parse('http://127.0.0.1:${current.port}$api/upload?generation=1&path=restart-$cycle.txt'));
        final content = utf8.encode('restart $cycle 原始字节');
        request.headers.set('X-LegnaSend-Upload', '1');
        request.headers.contentType = ContentType.binary;
        request.contentLength = content.length;
        request.add(content);
        final reply = await request.close();
        expect(reply.statusCode, 201);
        await reply.drain<void>();
        await until(
          () => tasks().any((task) => task.files.single.name == 'restart-$cycle.txt' && task.phase == TransferPhase.succeeded),
          'published task after restart $cycle',
        );
        expect(tasks().map((task) => task.id).toSet().containsAll(preservedIds), true, reason: 'Listener replacement retains bounded prior outcomes');
        final currentTask = tasks().singleWhere((task) => task.files.single.name == 'restart-$cycle.txt');
        expect(preservedIds.contains(currentTask.id), false, reason: 'Activity IDs must remain unique across listener replacement');
        expect(await container.notifier(webTransferActivityProvider).cancel(unobserved.id), false, reason: 'An old success cannot cancel a new task');
        final actual = await File('${rootDirectory.path}/restart-$cycle.txt').readAsBytes();
        expect(sha256.convert(actual), sha256.convert(content));
        preservedIds.add(currentTask.id);
        await server.stopServer();
        expect(container.read(webTransferActivityProvider).singleWhere((task) => task.id == currentTask.id).phase, TransferPhase.succeeded);
        restartEvidence.add({'cycle': cycle, 'status': reply.statusCode, 'id': currentTask.id, 'sha256': sha256.convert(actual).toString()});
      }
      final evidence = Platform.environment['LEGNASEND_ACTIVITY_EVIDENCE'];
      if (evidence != null) {
        final target = File(evidence);
        await target.parent.create(recursive: true);
        await target.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({
            'path': 'HTTP -> Rust activity -> FRB -> child isolate -> polling -> unified provider -> speed/cancel',
            'rangeSha256': sha256.convert(rangeBytes).toString(),
            'zipBytes': zip.length,
            'zipSha256': sha256.convert(zip).toString(),
            'uploadSha256': sha256.convert(payload).toString(),
            'sampledReceiveBytesPerSecond': speed,
            'tasks': [
              for (final task in tasks()) {'direction': task.direction.name, 'operation': task.operation, 'workspaceName': task.workspaceName, 'phase': task.phase.name, 'bytes': task.transferredBytes},
            ],
            'legacyInfoStatus': info.statusCode,
            'restartCycles': restartEvidence,
            'physicalMobileAcceptance': false,
          })}\n',
        );
      }
    } finally {
      uploading?.destroy();
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer();
      serverConnector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
