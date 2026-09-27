@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/directory_upload_approval.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/directory_upload_approval_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
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
  test('browser batch approval crosses real Rust bridge and Flutter provider without affecting native server', () async {
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
      final started = await server.startServer(alias: 'Wire fixture', port: 0, https: false).timeout(const Duration(seconds: 15));
      expect(started, isNotNull);
      const workspaceId = '11111111-1111-4111-8111-111111111111';
      Future<void> configure(int revision) => server.configureDirectoryWorkspaces(
        expectedGeneration: server.generation,
        config: jsonEncode({
          'revision': revision,
          'enabled': true,
          'workspaces': [
            {
              'id': workspaceId,
              'name': 'Wire uploads',
              'slug': 'uploads',
              'root': temp.path,
              'generation': revision,
              'visible': true,
              'allowUpload': true,
              'uploadApproval': true,
            },
          ],
        }),
      );
      await configure(1);
      final root = 'http://127.0.0.1:${started!.port}';
      Future<(int, String)> post(String suffix, Object data, {String? token}) async {
        final request = await client.postUrl(Uri.parse('$root/api/legnasend/v1/workspaces/$workspaceId/$suffix'));
        request.headers.set('x-legnasend-upload', '1');
        if (token != null) request.headers.set('x-legnasend-upload-token', token);
        final bytes = data is String ? utf8.encode(data) : utf8.encode(jsonEncode(data));
        request.headers.contentType = data is String ? ContentType.binary : ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        return (response.statusCode, await utf8.decoder.bind(response).join());
      }

      final approvals = container.notifier(directoryUploadApprovalProvider);
      Future<DirectoryUploadApproval> waitFor(String id, bool pending) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          final value = container.read(directoryUploadApprovalProvider).where((r) => r.files.any((file) => file.path == '$id.txt')).firstOrNull;
          if (value != null && value.pending == pending) return value;
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        throw StateError('Missing approval transition: $id pending=$pending');
      }

      Future<void> waitRemoved(String id) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          if (!container.read(directoryUploadApprovalProvider).any((r) => r.files.any((file) => file.path == '$id.txt'))) return;
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        throw StateError('Approval was not removed: $id');
      }

      Map<String, Object?> batch(String id) => {
        'requestId': id,
        'generation': 1,
        'files': [
          {'path': '$id.txt', 'size': 4, 'directory': false},
        ],
      };
      const acceptId = '22222222-2222-4222-8222-222222222222';
      final accepted = post('prepare-upload', batch(acceptId));
      final request = await waitFor(acceptId, true);
      expect(request.workspaceName, 'Wire uploads');
      expect(request.totalBytes, 4);
      expect(await File('${temp.path}/$acceptId.txt').exists(), false);
      expect(request.requestId, isNot(acceptId));
      await approvals.decide(request.requestId, true);
      expect((await waitFor(acceptId, false)).status, DirectoryUploadApprovalStatus.accepted);
      final (status, receipt) = await accepted;
      expect(status, 200);
      final token = (jsonDecode(receipt) as Map)['token'] as String;
      expect((await post('upload?generation=1&path=$acceptId.txt&directory=false', 'data', token: token)).$1, 201);
      expect(await File('${temp.path}/$acceptId.txt').readAsString(), 'data');
      const rejectId = '33333333-3333-4333-8333-333333333333';
      final rejected = post('prepare-upload', batch(rejectId));
      final rejectRequest = await waitFor(rejectId, true);
      await approvals.decide(rejectRequest.requestId, false);
      expect((await rejected).$1, 403);
      expect(await File('${temp.path}/$rejectId.txt').exists(), false);
      const cancelId = '44444444-4444-4444-8444-444444444444';
      final cancelled = post('prepare-upload', batch(cancelId));
      final cancelRequest = await waitFor(cancelId, true);
      expect((await post('cancel-upload-approval', {'requestId': cancelId, 'generation': 1})).$1, 200);
      expect((await cancelled).$1, 409);
      await waitRemoved(cancelId);
      await approvals.decide(cancelRequest.requestId, true);
      expect(await File('${temp.path}/$cancelId.txt').exists(), false);
      const changeId = '55555555-5555-4555-8555-555555555555';
      final changed = post('prepare-upload', batch(changeId));
      await waitFor(changeId, true);
      await configure(2);
      expect((await changed).$1, 409);
      await waitRemoved(changeId);
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
