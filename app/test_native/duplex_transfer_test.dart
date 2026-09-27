@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/send_session_lookup.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
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
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

/// Independent B / C peer: only original LocalSend v2 requests and responses.
class _Peer {
  final HttpServer server;
  final prepareSeen = Completer<void>();
  final acceptPrepare = Completer<void>();
  final uploadSeen = Completer<void>();
  final finishUpload = Completer<void>();
  final errors = <Object>[];
  final received = <int>[];
  final paths = <String>[];
  int prepares = 0;
  _Peer(this.server) {
    server.listen((request) => unawaited(_handle(request)));
  }
  static Future<_Peer> start() async => _Peer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Future<void> _handle(HttpRequest request) async {
    try {
      paths.add(request.uri.path);
      if (request.uri.path == '/api/localsend/v2/prepare-upload') {
        prepares++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        expect(body.keys.toSet(), {'info', 'files'});
        if (!prepareSeen.isCompleted) prepareSeen.complete();
        await acceptPrepare.future;
        final files = body['files'] as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'sessionId': 'outgoing-$prepares',
            'files': {for (final id in files.keys) id: 'token-$id'},
          }),
        );
      } else if (request.uri.path == '/api/localsend/v2/upload') {
        expect(request.uri.queryParameters.keys.toSet(), {'sessionId', 'fileId', 'token'});
        expect(request.uri.queryParameters['token'], 'token-${request.uri.queryParameters['fileId']}');
        received.addAll(await request.fold<List<int>>([], (all, bytes) => all..addAll(bytes)));
        if (!uploadSeen.isCompleted) uploadSeen.complete();
        await finishUpload.future;
      } else if (request.uri.path == '/api/localsend/v2/cancel') {
        await request.drain<void>();
      } else {
        throw StateError('Unexpected peer route');
      }
      await request.response.close();
    } on HttpException {
      // Locally cancelled pending prepare requests close their socket.
    } on SocketException {
      // Same cancellation contract as above.
    } catch (error) {
      errors.add(error);
    }
  }

  Future<void> close() async {
    if (!acceptPrepare.isCompleted) acceptPrepare.complete();
    if (!finishUpload.isCompleted) finishUpload.complete();
    await server.close(force: true);
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 600; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('Real duplex state did not arrive');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real native duplex accepts declines cancels and hides independently without stopping the listener', (tester) async {
    late Directory temp;
    late _Peer peer;
    _Peer? secondPeer;
    late RefenaContainer container;
    late ParentIsolateState parent;
    late HttpClient client;
    late ServerService server;
    late Device device;
    late int port;
    late String nativeToken;
    final outbound = List<int>.generate(768 * 1024, (i) => i % 251);
    final inbound = utf8.encode('received concurrently\u0000中文\n');
    final outgoingId = const Uuid().v4();
    Future<void>? sending;
    await tester.runAsync(() async {
      await initializeWorkspaceNativeBridge(Directory.current.parent.path);
      temp = await Directory.systemTemp.createTemp('legnasend-duplex-');
      peer = await _Peer.start();
      final security = await generateSecurityContext();
      final info = DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Duplex fixture', androidSdkInt: null);
      final sync = SyncState(
        rootIsolateToken: ServicesBinding.rootIsolateToken!,
        securityContext: security,
        deviceInfo: info,
        alias: 'A',
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
      when(persistence.getSecurityContext()).thenReturn(security);
      when(persistence.getDestination()).thenReturn(temp.path);
      when(persistence.getQuickSave()).thenReturn(QuickSaveMode.off);
      when(persistence.getCreateChecksums()).thenReturn(true);
      when(persistence.getVerifyChecksums()).thenReturn(true);
      when(persistence.isAutoFinish()).thenReturn(false);
      device = Device.empty.copyWith(ip: '127.0.0.1', port: peer.server.port, https: false, fingerprint: 'B' * 64, alias: 'B', version: '2.2');
      parent = ParentIsolateState(syncState: sync, discovery: null, httpUpload: uploadConnector, httpServer: serverConnector);
      container = RefenaContainer(
        overrides: [
          persistenceProvider.overrideWithValue(persistence),
          deviceRawInfoProvider.overrideWithValue(info),
          deviceFullInfoProvider.overrideWithBuilder((_) => device.copyWith(alias: 'A', fingerprint: security.certificateHash)),
          parentIsolateProvider.overrideWithNotifier(
            (_) => IsolateController(
              initialState: parent,
            ),
          ),
        ],
      );
      TransferNotification.init(
        NotificationStrings(
          titleReceiving: 'Receiving',
          titleSending: 'Sending',
          remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
          remainingTimeLong: ({required h, required m}) => '$h:$m',
        ),
      );
      client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
      server = container.notifier(serverProvider);
      port = (await server.startServer(alias: 'A', port: 0, https: false).timeout(const Duration(seconds: 15)))!.port;
      final draft = await createIntegrationApiKeyDraft(
        name: 'Native task manager',
        grant: jsonEncode({
          'scopes': ['nativeTasks.read', 'nativeTasks.control'],
          'workspaces': ['*'],
        }),
      );
      final record = jsonDecode(await draft.persistenceRecord());
      nativeToken = (await draft.takeSecret())!;
      draft.dispose();
      await server.integrationApiControl(
        expectedGeneration: server.generation,
        configuration: jsonEncode({
          'revision': 1,
          'enabled': true,
          'authRequired': true,
          'keys': [record],
          'globalLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 16},
          'keyLimits': {'perSecond': 1000, 'perMinute': 60000, 'concurrent': 8},
          'anonymousLimits': {'perSecond': 10, 'perMinute': 600, 'concurrent': 2},
          'anonymousGrant': {'scopes': [], 'workspaces': []},
          'allowedOrigins': [],
        }),
      );
    });
    // Native networking, save targets and session handlers are real. Only platform UI/cache path adapters are mocked.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => temp.path);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method != 'isMinimized',
    );
    await LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        ownsContainer: false,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: Routerino.navigatorKey,
            home: const Scaffold(body: Text('Home remains available')),
          ),
        ),
      ),
    );
    Future<(int, Map<String, dynamic>)> request(String path, {Object? body, List<int>? bytes}) async {
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/$path'));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      if (bytes != null) req.add(bytes);
      final response = await req.close();
      final text = await utf8.decoder.bind(response).join();
      return (response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
    }

    Future<(int, Map<String, dynamic>)> nativeRequest(String path, {Map<String, Object?>? body}) async {
      final req = await client.openUrl(body == null ? 'GET' : 'POST', Uri.parse('http://127.0.0.1:$port/api/legnasend/v1/integration$path'));
      req.headers.set('authorization', 'Bearer $nativeToken');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final response = await req.close();
      return (response.statusCode, jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>);
    }

    Future<void> receiveAction(String action) async {
      final (status, snapshot) = await nativeRequest('/native-tasks');
      expect(status, 200);
      final task = (snapshot['tasks'] as List).singleWhere((t) => t['direction'] == 'receive') as Map;
      final (controlled, result) = await nativeRequest(
        '/native-tasks/${task['id']}/control',
        body: {'epoch': snapshot['epoch'], 'version': task['version'], 'action': action},
      );
      expect(controlled, 200);
      expect(result['dispatched'], true);
    }

    Future<(int, Map<String, dynamic>)> prepare(String name) => request(
      'prepare-upload',
      body: {
        'info': {'alias': 'C', 'version': '2.2', 'fingerprint': 'C' * 64, 'port': peer.server.port, 'protocol': 'http', 'download': false},
        'files': {
          'incoming-file': {
            'id': 'incoming-file',
            'fileName': name,
            'size': inbound.length,
            'fileType': 'application/octet-stream',
            'sha256': sha256.convert(inbound).toString(),
          },
        },
      },
    );
    Future<void> hideIncoming() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ReceivePage), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text(t.receivePage.subTitle(n: 1)), findsOneWidget);
      expect(find.text(t.sendTab.selection.size(size: '${inbound.length} B')), findsOneWidget);
      Routerino.navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Home remains available'), findsOneWidget);
    }

    try {
      await tester.runAsync(() async {
        sending = container
            .notifier(sendProvider)
            .startSession(
              target: device,
              files: [
                CrossFile(
                  name: 'outbound.bin',
                  fileType: FileType.other,
                  size: outbound.length,
                  thumbnail: null,
                  asset: null,
                  path: null,
                  bytes: outbound,
                  lastModified: null,
                  lastAccessed: null,
                ),
              ],
              background: true,
              requestedSessionId: outgoingId,
              retainSession: true,
            );
        await peer.prepareSeen.future.timeout(const Duration(seconds: 10));
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.waiting);
      });
      // Incoming decisions work while A is waiting for B; Back hides, never declines or stops the service.
      late Future<(int, Map<String, dynamic>)> declined;
      await tester.runAsync(() async {
        declined = prepare('declined.bin');
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.waiting);
      });
      final declinedId = container.read(serverProvider)!.session!.sessionId;
      await hideIncoming();
      await tester.runAsync(() async {
        expect(container.read(serverProvider)!.session!.sessionId, declinedId);
        await receiveAction('reject');
        expect((await declined).$1, 403);
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.waiting);
      });
      late Future<(int, Map<String, dynamic>)> canceled;
      await tester.runAsync(() async {
        canceled = prepare('canceled.bin');
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.waiting);
      });
      await hideIncoming();
      await tester.runAsync(() async {
        await receiveAction('accept');
        expect((await canceled).$1, 200);
        await receiveAction('cancel');
        await _until(() => container.read(serverProvider)?.session == null);
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.waiting);
        expect(await File('${temp.path}/canceled.bin').exists(), false);
      });
      late Future<(int, Map<String, dynamic>)> accepted;
      await tester.runAsync(() async {
        peer.acceptPrepare.complete();
        await peer.uploadSeen.future.timeout(const Duration(seconds: 10));
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.sending);
        accepted = prepare('received.bin');
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.waiting);
      });
      await hideIncoming();
      await tester.runAsync(() async {
        final receiveId = container.read(serverProvider)!.session!.sessionId;
        // Old task controls must not target the new request.
        server.declineFileRequest(expectedSessionId: declinedId);
        expect(container.read(serverProvider)!.session!.sessionId, receiveId);
        final (_, beforeRename) = await nativeRequest('/native-tasks');
        final incoming = (beforeRename['tasks'] as List).singleWhere((t) => t['direction'] == 'receive') as Map;
        container.notifier(selectedReceivingFilesProvider).rename('incoming-file', 'received-renamed.bin');
        expect(
          (await nativeRequest(
            '/native-tasks/${incoming['id']}/control',
            body: {'epoch': beforeRename['epoch'], 'version': incoming['version'], 'action': 'accept'},
          )).$1,
          409,
        );
        await receiveAction('accept');
        final (status, handshake) = await accepted;
        expect(status, 200);
        // The original single-incoming-session rule remains in force.
        expect((await prepare('busy.bin')).$1, 409);
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.sending);
        expect(container.read(serverProvider)!.session!.status, SessionStatus.sending);
        final token = handshake['files']['incoming-file'];
        expect((await request('upload?sessionId=${handshake['sessionId']}&fileId=incoming-file&token=$token', bytes: inbound)).$1, 200);
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.finished);
        final path = container.read(serverProvider)!.session!.files['incoming-file']!.path!;
        expect(path, endsWith('received-renamed.bin'));
        expect(sha256.convert(await File(path).readAsBytes()), sha256.convert(inbound));
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.sending);
        await receiveAction('remove');
        expect(container.read(fileTransferProvider).getStatuses(outgoingId), isNotEmpty);
        peer.finishUpload.complete();
        await sending!.timeout(const Duration(seconds: 15));
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.finished);
        expect(sha256.convert(peer.received), sha256.convert(outbound));
        expect(container.read(serverProvider)!.port, port);
        expect(peer.errors, isEmpty);
        expect(peer.paths.every((p) => p.startsWith('/api/localsend/v2/')), true);
      });
      // The reverse cancellation direction: cancelling A→B does not cancel C→A.
      late Future<(int, Map<String, dynamic>)> surviving;
      late Future<void> canceledSend;
      final cancelId = const Uuid().v4();
      await tester.runAsync(() async {
        secondPeer = await _Peer.start();
        canceledSend = container
            .notifier(sendProvider)
            .startSession(
              target: device.copyWith(port: secondPeer!.server.port),
              files: [
                CrossFile(
                  name: 'cancel-outbound.bin',
                  fileType: FileType.other,
                  size: 3,
                  thumbnail: null,
                  asset: null,
                  path: null,
                  bytes: [1, 2, 3],
                  lastModified: null,
                  lastAccessed: null,
                ),
              ],
              background: true,
              requestedSessionId: cancelId,
              retainSession: true,
            );
        await secondPeer!.prepareSeen.future.timeout(const Duration(seconds: 10));
        surviving = prepare('surviving.bin');
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.waiting);
      });
      await hideIncoming();
      await tester.runAsync(() async {
        final receiveId = container.read(serverProvider)!.session!.sessionId;
        await server.acceptFileRequest({'incoming-file': 'surviving.bin'}, expectedSessionId: receiveId);
        final (status, handshake) = await surviving;
        expect(status, 200);
        await container.notifier(sendProvider).cancelSessionAndWait(cancelId);
        await canceledSend.timeout(const Duration(seconds: 10));
        final canceled = container.read(sendProvider)[cancelId]!;
        expect(canceled.status, SessionStatus.canceledBySender);
        expect(canceled.endTime, isNotNull);
        expect(canceled.sendingTasks, isEmpty);
        expect(isActiveSendSession(canceled), isFalse);
        expect(container.read(fileTransferProvider).getStatuses(cancelId), isNotEmpty);
        expect(container.read(serverProvider)!.session!.sessionId, receiveId);
        expect(container.read(serverProvider)!.session!.status, SessionStatus.sending);
        // Queue cancellation retains history until explicit removal. Closing that
        // terminal outgoing history must still leave the inbound transfer live.
        container.notifier(sendProvider).closeSession(cancelId);
        expect(container.read(sendProvider)[cancelId], isNull);
        expect(container.read(fileTransferProvider).getStatuses(cancelId), isEmpty);
        expect(container.read(serverProvider)!.session!.sessionId, receiveId);
        expect(container.read(serverProvider)!.session!.status, SessionStatus.sending);
        final token = handshake['files']['incoming-file'];
        final uploadPath = 'upload?sessionId=${handshake['sessionId']}&fileId=incoming-file&token=$token';
        // A failed incoming checksum does not affect completed sends; original whole-file retry succeeds.
        expect((await request(uploadPath, bytes: List.filled(inbound.length, 0))).$1, 422);
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.finishedWithErrors);
        expect(container.read(sendProvider)[outgoingId]!.status, SessionStatus.finished);
        expect((await request(uploadPath, bytes: inbound)).$1, 200);
        await _until(() => container.read(serverProvider)?.session?.status == SessionStatus.finished);
        final path = container.read(serverProvider)!.session!.files['incoming-file']!.path!;
        expect(sha256.convert(await File(path).readAsBytes()), sha256.convert(inbound));
        expect(container.read(serverProvider)!.port, port);
        server.closeSession(expectedSessionId: receiveId);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        for (final id in container.read(sendProvider).keys.toList()) {
          container.notifier(sendProvider).cancelSession(id);
        }
        await peer.close();
        await secondPeer?.close();
        client.close(force: true);
        if (container.read(serverProvider) != null) await server.stopServer();
        parent.httpServer!.isolate.kill();
        parent.httpUpload!.isolate.kill();
        container.disposeContainer();
        await temp.delete(recursive: true);
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    }
  });
}
