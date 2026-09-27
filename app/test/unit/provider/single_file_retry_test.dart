import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
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

class _Api extends Fake implements RustLibApi {
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _Token();
}

class _Isolates extends Fake implements IsolateController {}

class _Discovery extends NearbyDevicesService {
  final Device device;
  _Discovery(this.device)
    : super(isolateController: _Isolates(), favoriteService: FavoritesService(MockPersistenceService()), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {device.fingerprint: device}, signalingDevices: {});
}

class _Client extends Fake implements RsHttpClient {
  final offers = <wire.PrepareUploadRequestDto>[];
  final canceled = <String>[];
  final endpoints = <String>[];
  Completer<PrepareUploadResult>? gate;
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
    offers.add(payload);
    endpoints.add('$protocol/$ip:$port');
    return gate?.future ??
        PrepareUploadResult(
          statusCode: 200,
          response: wire.PrepareUploadResponseDto(sessionId: 'fresh-session', files: {for (final id in payload.files.keys) id: 'fresh-token'}),
        );
  }

  @override
  Future<void> cancel({required wire.ProtocolType protocol, required String ip, required int port, required String sessionId}) async =>
      canceled.add(sessionId);
}

class _Clients extends HttpClientCollection {
  final _Client client;
  _Clients(this.client) : super(privateKey: 'test', certificate: 'test', discovery: client);
  @override
  RsHttpClient pinnedTo(String fingerprint, {LocalSendRoute? localRoute}) => client;
}

class _Sender extends SendNotifier {
  _Sender(IsolateHttpUploadActionResult Function(IsolateHttpUploadFilesAction) superUpload) : super(uploadFiles: superUpload, cancelUpload: (_) {});
  void seed(SendSessionState value) => state = {...state, value.sessionId: value};
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _Api());
    TransferNotification.init(
      NotificationStrings(
        titleReceiving: 'Receiving',
        titleSending: 'Sending',
        remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
        remainingTimeLong: ({required h, required m}) => '$h:$m',
      ),
    );
  });
  late RefenaContainer container;
  late _Sender sender;
  late _Client client;
  late List<IsolateHttpUploadFilesAction> uploads;
  var failLast = false;
  final peer = Device.empty.copyWith(ip: '127.0.0.1', port: 53317, https: false, fingerprint: 'B' * 64);
  Future<void> drain() async {
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    uploads = [];
    failLast = false;
    client = _Client();
    sender = _Sender((IsolateHttpUploadFilesAction action) {
      uploads.add(action);
      return IsolateHttpUploadActionResult(
        taskId: uploads.length,
        events: Stream.fromIterable([
          for (final file in action.files)
            if (failLast && identical(file, action.files.last))
              HttpUploadFileFailedEvent(fileId: file.fileId, error: 'test disconnect', retainedConfirmed: true)
            else
              HttpUploadFileFinishedEvent(fileId: file.fileId),
        ]),
      );
    });
    container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        sendRecoveryStoreProvider.overrideWithValue(null),
        httpProvider.overrideWithBuilder((_) => _Clients(client)),
        deviceFullInfoProvider.overrideWithBuilder((_) => peer.copyWith(alias: 'Self', fingerprint: 'A' * 64)),
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(peer)),
        sendProvider.overrideWithNotifier((_) => sender),
      ],
    );
    container.read(sendProvider);
    final original = outgoing('original', status: SessionStatus.finishedWithErrors, size: 3).copyWith(target: peer, background: false);
    sender.seed(
      original.copyWith(
        files: {
          'out': original.files['out']!.copyWith(bytes: [1, 2, 3], errorMessage: 'HTTP 403: expired token'),
          'completed': original.files['out']!.copyWith(file: transferFile('completed', 3), bytes: [4, 5, 6]),
        },
      ),
    );
    container
        .notifier(fileTransferProvider)
        .setStatuses(sessionId: 'original', statuses: {'out': FileStatus.failed, 'completed': FileStatus.finished});
    container.notifier(fileTransferProvider).setStatus(sessionId: 'parallel-receive', fileId: 'incoming', status: FileStatus.sending);
  });
  tearDown(() async {
    container.dispose(sendQueueProvider);
    await drain();
    container.disposeContainer();
  });
  test('single-file retry inherits persisted identity but does not advertise it without a saved new manifest', () async {
    final old = container.read(sendProvider)['original']!;
    const key = '11111111-1111-4111-8111-111111111111';
    sender.seed(
      old.copyWith(
        files: {
          ...old.files,
          'out': old.files['out']!.copyWith(resumeKey: key, retainedAfterInterruption: false),
        },
      ),
    );
    final file = container.read(sendProvider)['original']!.files['out']!;
    final id = container.notifier(sendQueueProvider).retryFile(sessionId: 'original', file: file)!;
    await drain();
    expect(container.read(sendQueueProvider).singleWhere((job) => job.id == id).resumeKeys, [key]);
    expect(uploads.single.files.single.resumeKey, isNull, reason: 'No journal is configured; durable opt-in must fail closed');
    expect(client.canceled, isEmpty, reason: 'Unknown suspend acknowledgement must not race a standard cancel');
  });

  test('confirmed detached interruption may release old slot but unknown retention does not', () async {
    final old = container.read(sendProvider)['original']!;
    sender.seed(old.copyWith(files: {...old.files, 'out': old.files['out']!.copyWith(retainedAfterInterruption: false)}));
    await sender.releaseRemoteSession('original');
    expect(client.canceled, isEmpty);
    sender.seed(old.copyWith(files: {...old.files, 'out': old.files['out']!.copyWith(retainedAfterInterruption: true)}));
    await sender.releaseRemoteSession('original');
    expect(client.canceled, ['remote-original']);
  });

  test('whole-job retry inherits only remaining file keys and creates a fresh approved task', () async {
    failLast = true;
    final queue = container.notifier(sendQueueProvider);
    final id = queue.enqueue(peer, [
      for (final name in ['same', 'same'])
        CrossFile(
          name: name,
          fileType: FileType.other,
          size: 1,
          path: null,
          bytes: [1],
          thumbnail: null,
          asset: null,
          lastModified: null,
          lastAccessed: null,
        ),
    ]);
    await drain();
    final original = container.read(sendQueueProvider).singleWhere((job) => job.id == id);
    expect(original.terminal, isTrue);
    failLast = false;
    queue.retry(original);
    await drain();
    final next = container.read(sendQueueProvider).last;
    expect(next.id, isNot(id));
    expect(next.files, hasLength(1));
    expect(next.resumeKeys, [original.resumeKeys[1]]);
    expect(client.offers, hasLength(2));
    expect(client.offers.last.files, hasLength(1));
  });

  test('public manual single-file retry prepares a new remote session and preserves original successes', () async {
    final old = container.read(sendProvider)['original']!;
    await sender.sendFile(sessionId: 'original', file: old.files['out']!, isRetry: true);
    await drain();
    expect(client.offers, hasLength(1), reason: 'A terminal failed file must obtain fresh original-protocol tokens');
    expect(client.offers.single.files.values.single.fileName, 'out.bin');
    expect(uploads.single.remoteSessionId, 'fresh-session');
    expect(uploads.single.files.single.remoteFileToken, 'fresh-token');
    expect(container.read(sendProvider)['original'], same(old));
    expect(container.read(fileTransferProvider).getStatus(sessionId: 'original', fileId: 'completed'), FileStatus.finished);
    expect(container.read(fileTransferProvider).getStatus(sessionId: 'parallel-receive', fileId: 'incoming'), FileStatus.sending);
  });
  test('rapid repeated clicks return the same new task including its terminal result, removal permits a fresh one', () async {
    final old = container.read(sendProvider)['original']!;
    final queue = container.notifier(sendQueueProvider);
    final id = queue.retryFile(sessionId: 'original', file: old.files['out']!)!;
    expect(queue.retryFile(sessionId: 'original', file: old.files['out']!), id);
    await drain();
    expect(queue.retryFile(sessionId: 'original', file: old.files['out']!), id);
    expect(container.read(sendQueueProvider), hasLength(1));
    expect(client.offers, hasLength(1));
    await queue.removeAndWait(id);
    final next = queue.retryFile(sessionId: 'original', file: old.files['out']!)!;
    expect(next, isNot(id));
    await drain();
    expect(client.offers, hasLength(2));
  });

  test('manual retry pins the original actual endpoint instead of the current route preference', () async {
    container.notifier(sendRouteProvider).select(peer, const HttpChannel(host: '10.8.0.9', port: 53318, https: true));
    final old = container.read(sendProvider)['original']!;
    final id = container.notifier(sendQueueProvider).retryFile(sessionId: 'original', file: old.files['out']!)!;
    await drain();
    final job = container.read(sendQueueProvider).singleWhere((job) => job.id == id);
    expect(job.selectedChannel, const HttpChannel(host: '127.0.0.1', port: 53317, https: false));
    expect(client.endpoints.single, contains('127.0.0.1:53317'));
    expect(client.canceled, ['remote-original'], reason: 'Only the old terminal remote slot was released');
  });

  test('canceling a new retry waiting for approval does not alter original file results or parallel receive', () async {
    client.gate = Completer<PrepareUploadResult>();
    final old = container.read(sendProvider)['original']!;
    final queue = container.notifier(sendQueueProvider);
    final id = queue.retryFile(sessionId: 'original', file: old.files['out']!)!;
    await drain();
    expect(client.offers, hasLength(1));
    await queue.cancel(id);
    client.gate!.complete(
      PrepareUploadResult(
        statusCode: 200,
        response: wire.PrepareUploadResponseDto(
          sessionId: 'fresh-session',
          files: {for (final id in client.offers.single.files.keys) id: 'fresh-token'},
        ),
      ),
    );
    await drain();
    expect(uploads, isEmpty);
    expect(container.read(sendProvider)['original'], same(old));
    expect(container.read(fileTransferProvider).getStatus(sessionId: 'original', fileId: 'completed'), FileStatus.finished);
    expect(container.read(fileTransferProvider).getStatus(sessionId: 'parallel-receive', fileId: 'incoming'), FileStatus.sending);
    expect(client.canceled, contains('fresh-session'), reason: 'Late fresh approval is released, not resurrected');
  });

  test('queued retry cancellation, removal and disposal release bookkeeping without canceling other files', () async {
    client.gate = Completer<PrepareUploadResult>();
    final queue = container.notifier(sendQueueProvider);
    queue.enqueue(peer, [queuedFile('blocker', 1)]);
    await drain();
    final old = container.read(sendProvider)['original']!;
    final queued = queue.retryFile(sessionId: 'original', file: old.files['out']!)!;
    expect(queue.pendingSingleFileRetryReleaseCount, 1);
    await queue.cancel(queued);
    expect(queue.pendingSingleFileRetryReleaseCount, 0);
    await queue.removeAndWait(queued);
    final next = queue.retryFile(sessionId: 'original', file: old.files['out']!)!;
    expect(next, isNot(queued));
    expect(queue.pendingSingleFileRetryReleaseCount, 1);
    container.dispose(sendQueueProvider);
    expect(queue.pendingSingleFileRetryReleaseCount, 0);
    client.gate!.complete(const PrepareUploadResult(statusCode: 204));
    await drain();
    expect(client.offers, hasLength(1), reason: 'Neither queued retry contacted the peer');
    expect(container.read(sendProvider)['original'], same(old));
  });

  test('manual retry is unavailable until all old tasks drain, and non-retry cannot bypass failed-token protection', () async {
    final old = container.read(sendProvider)['original']!;
    await sender.sendFile(sessionId: 'original', file: old.files['out']!, isRetry: false);
    expect(uploads, isEmpty);
    sender.seed(old.copyWith(status: SessionStatus.sending));
    final active = container.read(sendProvider)['original']!;
    expect(container.notifier(sendQueueProvider).retryFile(sessionId: 'original', file: active.files['out']!), isNull);
    expect(client.canceled, isEmpty);
    expect(container.read(sendQueueProvider), isEmpty);
  });
}
