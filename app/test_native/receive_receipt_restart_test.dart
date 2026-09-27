@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

import '../../packages/localsend_isolates/test/support/native_bridge.dart';
import '../test/mocks.mocks.dart';

class _RealHttp extends HttpOverrides {}

class _Initial extends InitialData {
  final SendPort control;
  _Initial({required super.syncState, required this.control}) : super(logLevel: Level.WARNING);
}

Future<void> _setup(
  Stream<SendToIsolateData<IsolateTask<BaseHttpServerTask>>> messages,
  void Function(IsolateTaskStreamResult<HttpServerEvent>) emit,
  InitialData initial,
) async {
  final control = (initial as _Initial).control;
  final releases = ReceivePort();
  final gates = <String, Completer<void>>{};
  releases.listen((alias) => gates.remove(alias)?.complete());
  control.send(releases.sendPort);
  await setupHttpServerIsolate(
    messages,
    emit,
    initial,
    afterSave: (receipt) async {
      final gate = receipt.senderAlias == 'new' ? null : gates.putIfAbsent(receipt.senderAlias, Completer<void>.new);
      control.send(receipt);
      await gate?.future;
    },
  );
}

class _ReplaceParent extends ReduxAction<IsolateController, ParentIsolateState> {
  final ParentIsolateState next;
  _ReplaceParent(this.next);
  @override
  ParentIsolateState reduce() => next;
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Receipt restart fixture did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real late receipts survive listener restart without touching new receive UI; connection replacement and dispose detach', (
    tester,
  ) async {
    late Directory temp;
    late RefenaContainer container;
    late ServerService server;
    late ParentIsolateState parent;
    late HttpClient client;
    late int port;
    var disposed = false;
    final controls = ReceivePort();
    final children = <Isolate>[];
    SendPort? release;
    final saved = <HttpServerReceiveReceipt>[];
    final rawResults = <HttpServerFileUploadResultEvent>[];
    final subscriptions = <StreamSubscription>[];
    final writes = <List<ReceiveHistoryEntry>>[];
    final report = <String, Object?>{};
    subscriptions.add(
      controls.listen((event) {
        if (event is SendPort) release = event;
        if (event is HttpServerReceiveReceipt) saved.add(event);
      }),
    );
    await tester.runAsync(() async {
      await initializeWorkspaceNativeBridge(Directory.current.parent.path);
      temp = await Directory.systemTemp.createTemp('legnasend-receipt-restart-');
      final security = await generateSecurityContext();
      final info = DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Receipt restart fixture', androidSdkInt: null);
      final sync = SyncState(
        rootIsolateToken: ServicesBinding.rootIsolateToken!,
        securityContext: security,
        deviceInfo: info,
        alias: 'Receiver',
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
            task: _setup,
            param: _Initial(syncState: sync, control: controls.sendPort),
          );
      children.add(connector.isolate);
      subscriptions.add(
        connector.receiveFromIsolate.listen((e) {
          if (e.data is HttpServerFileUploadResultEvent) rawResults.add(e.data! as HttpServerFileUploadResultEvent);
        }),
      );
      parent = ParentIsolateState(syncState: sync, discovery: null, httpUpload: null, httpServer: connector);
      final persistence = MockPersistenceService();
      when(persistence.getSecurityContext()).thenReturn(security);
      when(persistence.getDestination()).thenReturn(temp.path);
      when(persistence.getQuickSave()).thenReturn(QuickSaveMode.off);
      when(persistence.getVerifyChecksums()).thenReturn(true);
      when(persistence.isAutoFinish()).thenReturn(false);
      when(persistence.isSaveToHistory()).thenReturn(true);
      when(persistence.getReceiveHistory()).thenReturn([]);
      when(persistence.setReceiveHistory(any)).thenAnswer((call) async {
        writes.add(List<ReceiveHistoryEntry>.from(call.positionalArguments.single as List));
      });
      container = RefenaContainer(
        overrides: [
          persistenceProvider.overrideWithValue(persistence),
          deviceRawInfoProvider.overrideWithValue(info),
          deviceFullInfoProvider.overrideWithBuilder((_) => Device.empty.copyWith(alias: 'Receiver', fingerprint: security.certificateHash)),
          parentIsolateProvider.overrideWithNotifier((_) => IsolateController(initialState: parent)),
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
      client = _RealHttp().createHttpClient(null)..findProxy = (_) => 'DIRECT';
      server = container.notifier(serverProvider);
      port = (await server.startServer(alias: 'Receiver', port: 0, https: false))!.port;
    });
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
            home: const Scaffold(body: Text('Receipt fixture')),
          ),
        ),
      ),
    );
    final bytes = utf8.encode('receipt restart 中文\u0000\n');
    Future<(int, Map<String, dynamic>)> request(String path, {Map<String, Object?>? body, List<int>? data}) async {
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/$path'));
      req.persistentConnection = false;
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      if (data != null) req.add(data);
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return (res.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
    }

    Future<Map<String, dynamic>> prepare(String alias) async {
      final pending = request(
        'prepare-upload',
        body: {
          'info': {'alias': alias, 'version': '2.2', 'fingerprint': 'same-peer', 'port': 53317, 'protocol': 'http', 'download': false},
          'files': {
            'same-id': {
              'id': 'same-id',
              'fileName': '$alias.txt',
              'size': bytes.length,
              'fileType': 'text/plain',
              'sha256': sha256.convert(bytes).toString(),
            },
          },
        },
      );
      await _until(() => server.state?.session?.senderAlias == alias && server.state?.session?.status == SessionStatus.waiting);
      await server.acceptFileRequest({'same-id': '$alias-accepted.txt'}, expectedSessionId: server.state!.session!.sessionId);
      final result = await pending;
      expect(result.$1, 200);
      return result.$2;
    }

    Future<void> upload(Map<String, dynamic> data) async {
      final query = Uri(
        queryParameters: {
          'sessionId': data['sessionId'] as String,
          'fileId': 'same-id',
          'token': (data['files'] as Map<String, dynamic>)['same-id'] as String,
        },
      ).query;
      expect((await request('upload?$query', data: bytes)).$1, 200);
    }

    try {
      await tester.runAsync(() async {
        final old = await prepare('old');
        await upload(old);
        await _until(() => saved.any((r) => r.senderAlias == 'old'));
        expect(container.read(receiveHistoryProvider), isEmpty);
        final stopWatch = Stopwatch()..start();
        await server.stopServer().timeout(const Duration(seconds: 5));
        expect(rawResults.where((e) => e.receipt?.senderAlias == 'old'), isEmpty);
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await probe.close();
        report['stopBeforeReceiptMs'] = stopWatch.elapsedMilliseconds;
        expect((await server.startServer(alias: 'Replacement', port: port, https: false))!.port, port);
        final next = await prepare('new');
        final sessionBefore = server.state!.session;
        final progressBefore = container.read(fileTransferProvider);
        final serverBefore = server.state;
        release!.send('old');
        await _until(() => container.read(receiveHistoryProvider).length == 1);
        expect(identical(server.state, serverBefore), true);
        expect(identical(server.state!.session, sessionBefore), true);
        expect(identical(container.read(fileTransferProvider), progressBefore), true);
        final oldEntry = container.read(receiveHistoryProvider).single;
        expect(oldEntry.senderAlias, 'old');
        expect(oldEntry.fileName, 'old-accepted.txt');
        expect(await File(oldEntry.path!).readAsBytes(), bytes);
        await upload(next);
        await _until(() => container.read(receiveHistoryProvider).length == 2 && server.state!.session!.status == SessionStatus.finished);
        expect(writes, hasLength(2), reason: 'Normal result and control receipt paths must deduplicate');
        report['newSessionUnchangedByOldReceipt'] = true;
        report['successfulFilesSha256'] = sha256.convert(bytes).toString();

        final stopped = await prepare('stopped');
        await upload(stopped);
        await _until(() => saved.any((r) => r.senderAlias == 'stopped'));
        await server.stopServer();
        release!.send('stopped');
        await _until(() => container.read(receiveHistoryProvider).length == 3);
        expect(server.state, isNull);
        report['receiptWhileStopped'] = true;

        await server.startServer(alias: 'Before replacement', port: port, https: false);
        final replaced = await prepare('replaced');
        await upload(replaced);
        await _until(() => saved.any((r) => r.senderAlias == 'replaced'));
        await server.stopServer();
        // A replacement child has its own raw control channel. Detach the old
        // one before another listener starts; its late saved result is ignored.
        final oldRelease = release!;
        final nextConnector =
            await TypedIsolates.startIsolate<
              IsolateTaskStreamResult<HttpServerEvent>,
              SendToIsolateData<IsolateTask<BaseHttpServerTask>>,
              InitialData
            >(
              task: _setup,
              param: _Initial(syncState: parent.syncState, control: controls.sendPort),
            );
        children.add(nextConnector.isolate);
        subscriptions.add(
          nextConnector.receiveFromIsolate.listen((e) {
            if (e.data is HttpServerFileUploadResultEvent) rawResults.add(e.data! as HttpServerFileUploadResultEvent);
          }),
        );
        parent = parent.copyWith(httpServer: nextConnector);
        container.redux(parentIsolateProvider).dispatch(_ReplaceParent(parent));
        await _until(() => release != oldRelease);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        oldRelease.send('replaced');
        await _until(() => rawResults.any((e) => e.receipt?.senderAlias == 'replaced'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(container.read(receiveHistoryProvider), hasLength(3));
        report['oldConnectorDetached'] = true;
        await server.startServer(alias: 'Before dispose', port: port, https: false);
        final disposing = await prepare('disposed');
        await upload(disposing);
        await _until(() => saved.any((r) => r.senderAlias == 'disposed'));
        await server.stopServer();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() async {
        container.disposeContainer();
        disposed = true;
        final before = writes.length;
        release!.send('disposed');
        await _until(() => rawResults.any((e) => e.receipt?.senderAlias == 'disposed'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(writes.length, before);
        report['disposeDetached'] = true;
        report['historyWrites'] = writes.length;
        report['boundary'] = 'Real app providers, child isolate, same-process listener stop/rebind, original HTTP and disk; not crash recovery';
        final output = File('../build/test-results/batch29/receipts/restart-results.json');
        await output.parent.create(recursive: true);
        await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        client.close(force: true);
        if (!disposed) {
          await server.stopServer();
          container.disposeContainer();
        }
        for (final child in children) {
          child.kill();
        }
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        controls.close();
        await temp.delete(recursive: true);
      });
    }
  });
}
