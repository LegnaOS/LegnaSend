import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as wire;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

class _Token extends Fake implements RsCancellationToken {
  @override
  void cancel() {}
}

class _Client extends Fake implements RsHttpClient {
  int prepares = 0;
  final cancels = <String>[];
  Object? requestError;
  @override
  Future<PrepareUploadResult> prepareUpload({
    required wire.ProtocolType protocol,
    required String ip,
    required int port,
    required wire.PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) async {
    prepares++;
    if (requestError case final error?) throw error;
    return PrepareUploadResult(
      statusCode: 200,
      response: wire.PrepareUploadResponseDto(sessionId: 'remote', files: {for (final id in payload.files.keys) id: 'token'}),
    );
  }

  @override
  Future<void> cancel({required wire.ProtocolType protocol, required String ip, required int port, required String sessionId}) async {
    cancels.add(sessionId);
  }
}

class _Api extends Fake implements RustLibApi {
  final _Client client = _Client();
  final routes = <LocalSendRoute?>[];
  Object? createError;
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _Token();
  @override
  RsHttpClient crateApiHttpCreateClient({
    required String privateKey,
    required String cert,
    required LsHttpClientVersion version,
    String? expectedFingerprint,
    int? timeoutMs,
    String? localAddress,
    String? interfaceName,
    String? androidNetworkHandle,
    String? androidNetworkEpoch,
  }) {
    routes.add(localAddress == null ? null : LocalSendRoute(interfaceName: interfaceName!, localAddress: localAddress));
    if (createError case final error?) throw error;
    return client;
  }
}

void main() {
  final api = _Api();
  const route = LocalSendRoute(interfaceName: 'fixture-interface', localAddress: '127.0.0.1');
  final device = Device.empty.copyWith(ip: '127.0.0.1', fingerprint: 'B' * 64, port: 53317, https: false);
  late RefenaContainer container;
  late SendNotifier sender;
  late StreamController<HttpUploadEvent> upload;
  late Completer<IsolateHttpUploadFilesAction> dispatched;
  setUpAll(() {
    RustLib.initMock(api: api);
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '$h:$m',
      ),
    );
  });
  setUp(() {
    api.routes.clear();
    api.createError = null;
    api.client.requestError = null;
    api.client.prepares = 0;
    api.client.cancels.clear();
    upload = StreamController<HttpUploadEvent>();
    dispatched = Completer();
    sender = SendNotifier(
      uploadFiles: (action) {
        dispatched.complete(action);
        return IsolateHttpUploadActionResult(taskId: 1, events: upload.stream);
      },
      cancelUpload: (_) {},
    );
    container = RefenaContainer(
      overrides: [
        sendProvider.overrideWithNotifier((_) => sender),
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        httpProvider.overrideWithBuilder((_) => HttpClientCollection(privateKey: 'fixture', certificate: 'fixture', discovery: api.client)),
        deviceFullInfoProvider.overrideWithBuilder((_) => device.copyWith(alias: 'self', fingerprint: 'A' * 64)),
      ],
    );
    container.read(sendProvider);
  });
  tearDown(() async {
    if (upload.hasListener && !upload.isClosed) await upload.close();
    container.disposeContainer();
  });
  Future<void> start({LocalSendRoute? selected = route}) => sender.startSession(
    target: device,
    files: [queuedFile('data', 8)],
    background: true,
    requestedSessionId: 'local-route',
    retainSession: true,
    localRoute: selected,
  );
  test('same immutable route reaches preparation, isolate upload and remote cancellation', () async {
    final running = start();
    final action = await dispatched.future.timeout(const Duration(seconds: 5));
    expect(api.routes, [route]);
    expect(action.localRoute, same(route));
    expect(container.read(sendProvider)['local-route']!.localRoute, same(route));
    await sender.cancelSessionAndWait('local-route');
    expect(api.routes, [route, route]);
    expect(api.client.cancels, ['remote']);
    expect(container.read(sendProvider)['local-route']!.localRoute, same(route));
    await upload.close();
    await running;
  });
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    test('binding constructor fails visibly without unbound fallback in ${locale.languageTag}', () async {
      await LocaleSettings.setLocale(locale);
      api.createError = const RsHttpClientError.io('local-route-unavailable: interface disappeared');
      await start();
      final state = container.read(sendProvider)['local-route']!;
      expect(state.status, SessionStatus.finishedWithErrors);
      expect(state.localRoute, same(route));
      expect(state.errorMessage, SendRouteStrings(locale).localRouteUnavailable);
      expect(state.endTime, isNotNull);
      expect(api.routes, [route]);
      expect(api.client.prepares, 0);
      expect(dispatched.isCompleted, false);
    });
  }
  test('IP family mismatch fails before creating any HTTP client', () async {
    await start(
      selected: const LocalSendRoute(interfaceName: 'fixture-v6', localAddress: '::1'),
    );
    final state = container.read(sendProvider)['local-route']!;
    expect(state.status, SessionStatus.finishedWithErrors);
    expect(state.errorMessage, SendRouteStrings(LocaleSettings.currentLocale).addressFamilyMismatch);
    expect(api.routes, isEmpty);
    expect(api.client.prepares, 0);
  });
  test('preparation route error is localized but general socket failures retain diagnosis', () async {
    api.client.requestError = const RsHttpClientError.io('local-route-invalid: bad interface');
    await start();
    expect(container.read(sendProvider)['local-route']!.errorMessage, SendRouteStrings(LocaleSettings.currentLocale).localRouteInvalid);
    api.client.requestError = const RsHttpClientError.reqwest('Connection reset by peer');
    await start();
    expect(container.read(sendProvider)['local-route']!.errorMessage, contains('Connection reset by peer'));
    expect(api.routes, [route, route]);
  });
  test('child binding failure completes its file with localized error, never successful progress', () async {
    final running = start();
    final action = await dispatched.future.timeout(const Duration(seconds: 5));
    final id = action.files.single.fileId;
    upload.add(HttpUploadFileFailedEvent(fileId: id, error: 'RsHttpClientError.io(field0: local-route-unavailable: removed)'));
    await upload.close();
    await running;
    final state = container.read(sendProvider)['local-route']!;
    expect(state.status, SessionStatus.finishedWithErrors);
    expect(state.files[id]!.errorMessage, SendRouteStrings(LocaleSettings.currentLocale).localRouteUnavailable);
    expect(container.read(fileTransferProvider).getStatus(sessionId: state.sessionId, fileId: id), FileStatus.failed);
    expect(api.routes, [route]);
  });
  test('default automatic routing passes null through creation and upload task', () async {
    final running = start(selected: null);
    final action = await dispatched.future.timeout(const Duration(seconds: 5));
    expect(action.localRoute, isNull);
    expect(api.routes, [null]);
    upload.add(HttpUploadFileFinishedEvent(fileId: action.files.single.fileId));
    await upload.close();
    await running;
    expect(container.read(sendProvider)['local-route']!.status, SessionStatus.finished);
  });
  test('shared route mapper preserves exact immutable strings and null remains caller-owned', () {
    expect(LocalSendRoute.fromJson(route.toJson()), route);
    expect(LocalSendRoute.fromJson({'interfaceName': 'en9', 'localAddress': 'fe80::1%9'}).localAddress, 'fe80::1%9');
  });
}
