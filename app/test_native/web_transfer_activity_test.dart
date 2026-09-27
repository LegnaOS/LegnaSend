@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
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
  test('temporary web approval, range bytes and scoped cancellation cross real host bridge', () async {
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('host-api-wire-');
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
    try {
      final small = File('${temp.path}/small.txt');
      await small.writeAsString('abcdefghijklmnop');
      final large = File('${temp.path}/large.bin');
      final largeHandle = await large.open(mode: FileMode.write);
      await largeHandle.truncate(64 * 1024 * 1024);
      await largeHandle.close();
      CrossFile source(File file, int size) => CrossFile(
        name: file.uri.pathSegments.last,
        fileType: FileType.other,
        size: size,
        thumbnail: null,
        asset: null,
        path: file.path,
        bytes: null,
        lastModified: null,
        lastAccessed: null,
      );
      await server.restartServerWithWebDownload(
        alias: 'Wire fixture',
        port: 0,
        https: false,
        files: [source(small, 16), source(large, 64 * 1024 * 1024)],
      );
      final root = 'http://127.0.0.1:${container.read(serverProvider)!.port}';
      final prepare = () async {
        final response = await (await client.postUrl(Uri.parse('$root/api/localsend/v2/prepare-download'))).close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      }();
      Future<void> until(bool Function() done) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (!done()) {
          if (DateTime.now().isAfter(end)) throw StateError('Missing web activity transition');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      await until(() => container.read(serverProvider)?.webDownloadState?.sessions.isNotEmpty == true);
      final waiting = collectWebApprovalActivities(container.read(serverProvider)!.webDownloadState).single;
      expect(waiting.kind, TransferActivityKind.webApproval);
      expect(waiting.phase, TransferPhase.waiting);
      server.acceptWebDownloadRequest(waiting.id);
      final approved = await prepare;
      final ids = (approved['files'] as Map<String, dynamic>);
      final smallId = ids.entries.firstWhere((entry) => (entry.value as Map)['fileName'] == 'small.txt').key;
      final largeId = ids.entries.firstWhere((entry) => (entry.value as Map)['fileName'] == 'large.bin').key;
      String url(String id) => '$root/api/localsend/v2/download?sessionId=${approved['sessionId']}&fileId=$id';
      final range = await client.getUrl(Uri.parse(url(smallId)));
      range.headers.set('range', 'bytes=3-7');
      final response = await range.close();
      expect(response.statusCode, 206);
      expect(await utf8.decoder.bind(response).join(), 'defgh');
      await until(() => container.read(webTransferActivityProvider).any((task) => task.phase == TransferPhase.succeeded));
      final completed = container.read(webTransferActivityProvider).single;
      expect(completed.totalBytes, 5);
      expect(completed.transferredBytes, 5);
      final pending = await (await client.getUrl(Uri.parse(url(largeId)))).close();
      await until(() => container.read(webTransferActivityProvider).any((task) => task.active));
      final active = container.read(webTransferActivityProvider).firstWhere((task) => task.active);
      expect(active.kind, TransferActivityKind.webResponse);
      expect(await container.notifier(webTransferActivityProvider).cancel(active.id), true);
      await expectLater(pending.drain<void>(), throwsA(isA<HttpException>()));
      await until(() => container.read(webTransferActivityProvider).any((task) => task.id == active.id && task.phase == TransferPhase.canceled));
      expect(container.read(serverProvider)!.web, isNotNull);
      final again = await (await client.getUrl(Uri.parse(url(smallId)))).close();
      expect(await utf8.decoder.bind(again).join(), 'abcdefghijklmnop');
      final info = await (await client.getUrl(Uri.parse('$root/api/localsend/v2/info'))).close();
      expect(info.statusCode, 200);
      await info.drain<void>();
    } finally {
      client.close(force: true);
      if (container.read(serverProvider) != null) await server.stopServer();
      serverConnector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
