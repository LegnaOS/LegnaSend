@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Timed out waiting for real server state');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real child isolate repeatedly shares after disconnect rejection missing source and stale approval', () async {
    expect(Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'], isNotNull);
    await initializeWorkspaceNativeBridge(Directory.current.parent.path);
    final temp = await Directory.systemTemp.createTemp('legnasend-repeat-share-');
    final source = File('${temp.path}/shared.txt');
    final bytes = utf8.encode('repeat share bytes 中文\n');
    await source.writeAsBytes(bytes);
    final sync = SyncState(
      rootIsolateToken: ServicesBinding.rootIsolateToken!,
      securityContext: const StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: 'fixture'),
      deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Share fixture', androidSdkInt: null),
      alias: 'Share fixture',
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
          task: setupHttpServerIsolate,
          param: InitialData(syncState: sync, logLevel: Level.WARNING),
        );
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState(syncState: sync, discovery: null, httpUpload: null, httpServer: connector),
          ),
        ),
      ],
    );
    final client = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp())..findProxy = (_) => 'DIRECT';
    final server = container.notifier(serverProvider);
    Socket? abandoned;
    try {
      final started = (await server.startServer(alias: 'Share fixture', port: 0, https: false))!;
      final root = 'http://127.0.0.1:${started.port}';
      Future<(int, List<int>)> request(String method, String path, {String? range}) async {
        final req = await client.openUrl(method, Uri.parse('$root$path'));
        if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
        final res = await req.close();
        return (res.statusCode, await res.fold<List<int>>([], (all, chunk) => all..addAll(chunk)));
      }

      Future<void> publish(int round) => server.restartServerWithWebDownload(
        alias: started.alias,
        port: started.port,
        https: false,
        allowUpload: true,
        files: [
          CrossFile(
            name: 'round-$round.txt',
            fileType: FileType.text,
            size: bytes.length,
            thumbnail: null,
            asset: null,
            path: source.path,
            bytes: null,
            lastModified: null,
            lastAccessed: null,
          ),
        ],
      );
      String pending() => server.state!.webDownloadState!.sessions.values.singleWhere((session) => session.pending).sessionId;
      Future<String> waitPending() async {
        await _until(() => server.state!.webDownloadState!.sessions.values.any((session) => session.pending));
        return pending();
      }

      String? previousSession;
      String? previousFile;
      for (var round = 0; round < 10; round++) {
        await publish(round);
        server.setWebDownloadAutoAccept(false);
        expect(server.state!.port, started.port);
        expect(server.state!.webUpload, true);
        expect(container.read(parentIsolateProvider).syncState.serverRunning, true);
        expect(container.read(parentIsolateProvider).syncState.download, true);
        expect(server.state!.webDownloadState!.sessions, isEmpty);
        if (previousSession != null) {
          expect((await request('GET', '/api/localsend/v2/download?sessionId=$previousSession&fileId=$previousFile')).$1, 403);
        }
        abandoned = await Socket.connect(InternetAddress.loopbackIPv4, started.port);
        abandoned.write('POST /api/localsend/v2/prepare-download HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n');
        await abandoned.flush();
        final abandonedId = await waitPending();
        abandoned.destroy();
        abandoned = null;
        await _until(() => !server.state!.webDownloadState!.sessions.containsKey(abandonedId));
        server.acceptWebDownloadRequest(abandonedId);

        final rejected = request('POST', '/api/localsend/v2/prepare-download');
        final rejectedId = await waitPending();
        server.declineWebDownloadRequest(rejectedId);
        expect((await rejected).$1, 403);
        await _until(() => !server.state!.webDownloadState!.sessions.containsKey(rejectedId));

        final accepted = request('POST', '/api/localsend/v2/prepare-download');
        final id = await waitPending();
        server.acceptWebDownloadRequest(id);
        final (status, body) = await accepted;
        expect(status, 200);
        final manifest = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        expect(manifest['sessionId'], id);
        final file = (manifest['files'] as Map<String, dynamic>).keys.single;
        final url = '/api/localsend/v2/download?sessionId=$id&fileId=$file';
        await source.delete();
        expect((await request('GET', url)).$1, 404);
        await source.writeAsBytes(bytes);
        final complete = await request('GET', url);
        expect(complete.$1, 200);
        expect(complete.$2, bytes);
        final resumed = await request('GET', url, range: 'bytes=7-');
        expect(resumed.$1, 206);
        expect(resumed.$2, bytes.sublist(7));
        final refresh = await request('POST', '/api/localsend/v2/prepare-download?sessionId=$id');
        expect(refresh.$1, 200);
        expect(jsonDecode(utf8.decode(refresh.$2))['sessionId'], id);
        expect(server.state!.webDownloadState!.sessions.values.where((session) => session.pending), isEmpty);
        expect((await request('GET', '/api/localsend/v2/info')).$1, 200);
        server.setWebDownloadAutoAccept(true);
        final automatic = await request('POST', '/api/localsend/v2/prepare-download');
        expect(automatic.$1, 200);
        expect(jsonDecode(utf8.decode(automatic.$2))['sessionId'], isNot(id));
        await _until(() => server.state!.webDownloadState!.sessions.values.every((session) => !session.pending));
        server.setWebDownloadAutoAccept(false);

        // Replacing a share resolves its old waiter; a late UI decision cannot
        // create an approval card or revoke the new share from the same peer IP.
        final stale = request('POST', '/api/localsend/v2/prepare-download');
        final staleId = await waitPending();
        await publish(round);
        expect((await stale).$1, 410);
        server.acceptWebDownloadRequest(staleId);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(server.state!.webDownloadState!.sessions, isEmpty);
        // Rapid page-level share toggles must close only the browser share,
        // leaving the listener available for original-protocol receiving.
        final closing = request('POST', '/api/localsend/v2/prepare-download');
        final closingId = await waitPending();
        final closingGeneration = server.generation;
        expect(await server.stopWebShare(expectedGeneration: closingGeneration), true);
        expect((await closing).$1, 410);
        expect(server.state!.web, isNull);
        expect(container.read(parentIsolateProvider).syncState.serverRunning, true);
        expect(container.read(parentIsolateProvider).syncState.download, false);
        expect(server.state!.port, started.port);
        expect((await request('GET', '/api/localsend/v2/info')).$1, 200);
        server.acceptWebDownloadRequest(closingId);
        await publish(round);
        expect(await server.stopWebShare(expectedGeneration: closingGeneration), false);
        expect(server.state!.web, isNotNull);

        // Queue stop/start without awaiting between clicks, then restart once.
        // The actual lifecycle queue must serialize native stop and bind ACKs.
        final stopping = server.stopServer();
        final starting = server.startServer(alias: started.alias, port: started.port, https: false);
        await stopping;
        expect((await starting)!.port, started.port);
        expect(server.state!.web, isNull);
        expect((await request('GET', '/api/localsend/v2/info')).$1, 200);
        final restarted = await server.restartServer(alias: started.alias, port: started.port, https: false);
        expect(restarted!.port, started.port);
        await publish(round);
        server.setWebDownloadAutoAccept(true);
        final reopened = await request('POST', '/api/localsend/v2/prepare-download');
        expect(reopened.$1, 200);
        final reopenedManifest = jsonDecode(utf8.decode(reopened.$2)) as Map<String, dynamic>;
        final reopenedId = reopenedManifest['sessionId'] as String;
        final reopenedFile = (reopenedManifest['files'] as Map<String, dynamic>).keys.single;
        final reopenedDownload = await request('GET', '/api/localsend/v2/download?sessionId=$reopenedId&fileId=$reopenedFile');
        expect(reopenedDownload.$1, 200);
        expect(reopenedDownload.$2, bytes);
        expect((await request('GET', '/api/localsend/v2/info')).$1, 200);
        server.setWebDownloadAutoAccept(false);
        previousSession = id;
        previousFile = file;
      }
      expect(await source.readAsBytes(), bytes);
      expect(server.state!.port, started.port);

      // A temporary preferred-port conflict must advertise the actual fallback,
      // and releasing that conflict lets the next restart reclaim preference.
      await server.stopServer();
      expect(container.read(parentIsolateProvider).syncState.serverRunning, false);
      expect(container.read(parentIsolateProvider).syncState.download, false);
      final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, started.port);
      try {
        final fallback = (await server.startServer(alias: started.alias, port: started.port, https: false))!;
        expect(fallback.port, isNot(started.port));
        await _until(() => container.read(parentIsolateProvider).syncState.port == fallback.port);
        final probe = await client.getUrl(Uri.parse('http://127.0.0.1:${fallback.port}/api/localsend/v2/info'));
        final response = await probe.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        await publish(10);
        expect(server.state!.port, fallback.port);
        final page = await client.getUrl(Uri.parse('http://127.0.0.1:${fallback.port}/share'));
        final pageResponse = await page.close();
        expect(pageResponse.statusCode, 200);
        await pageResponse.drain<void>();
      } finally {
        await blocker.close();
      }
      final preferred = await server.restartServer(alias: started.alias, port: started.port, https: false);
      expect(preferred!.port, started.port);
      await _until(() => container.read(parentIsolateProvider).syncState.port == started.port);
      await publish(11);
      expect((await request('GET', '/share')).$1, 200);
      expect((await request('GET', '/api/localsend/v2/info')).$1, 200);
    } finally {
      abandoned?.destroy();
      client.close(force: true);
      if (server.state != null) await server.stopServer();
      connector.isolate.kill();
      container.disposeContainer();
      await temp.delete(recursive: true);
    }
  });
}
