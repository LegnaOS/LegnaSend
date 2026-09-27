import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as wire;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

/// Deterministic late acknowledgement boundary: this is not a wire/FFI test.
class _Token extends Fake implements RsCancellationToken {
  int canceled = 0;
  @override
  void cancel() {
    canceled++;
  }
}

class _Api extends Fake implements RustLibApi {
  final tokens = <_Token>[];
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() {
    final token = _Token();
    tokens.add(token);
    return token;
  }
}

class _Client extends Fake implements RsHttpClient {
  final requests = <Completer<PrepareUploadResult>>[];
  final canceled = <String>[];
  @override
  Future<PrepareUploadResult> prepareUpload({
    required wire.ProtocolType protocol,
    required String ip,
    required int port,
    required wire.PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) {
    final result = Completer<PrepareUploadResult>();
    requests.add(result);
    return result.future;
  }

  @override
  Future<void> cancel({required wire.ProtocolType protocol, required String ip, required int port, required String sessionId}) async {
    canceled.add(sessionId);
  }
}

class _Clients extends HttpClientCollection {
  final _Client client;
  _Clients(this.client) : super(privateKey: 'fixture', certificate: 'fixture', discovery: client);
  @override
  RsHttpClient pinnedTo(String fingerprint, {LocalSendRoute? localRoute}) => client;
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  late _Client client;
  late RefenaContainer container;
  late SendNotifier sender;
  final device = Device.empty.copyWith(ip: '127.0.0.1', port: 53317, https: false, fingerprint: 'B' * 64);
  setUp(() {
    api.tokens.clear();
    client = _Client();
    container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(MockPersistenceService()),
        httpProvider.overrideWithBuilder((_) => _Clients(client)),
        deviceFullInfoProvider.overrideWithBuilder((_) => device.copyWith(alias: 'Self', fingerprint: 'A' * 64)),
      ],
    );
    sender = container.notifier(sendProvider);
  });
  tearDown(() => container.disposeContainer());
  Future<void> start() =>
      sender.startSession(target: device, files: [queuedFile('data', 10)], background: true, requestedSessionId: 'same', retainSession: true);
  for (final lateStatus in [200, 204, 500]) {
    test('late prepare status $lateStatus cannot mutate replacement attempt or clear its cancellation token', () async {
      final first = start();
      final oldAttempt = sender.sessionAttemptIdentity('same');
      expect(client.requests, hasLength(1));
      sender.cancelSession('same');
      final second = start();
      final newAttempt = sender.sessionAttemptIdentity('same');
      expect(newAttempt, isNot(same(oldAttempt)));
      expect(client.requests, hasLength(2));
      final replacement = container.read(sendProvider)['same'];
      if (lateStatus == 500) {
        client.requests[0].completeError(const RsHttpClientError.statusCode(status: 500));
      } else {
        client.requests[0].complete(
          PrepareUploadResult(
            statusCode: lateStatus,
            response: lateStatus == 200 ? const wire.PrepareUploadResponseDto(sessionId: 'old-remote', files: {}) : null,
          ),
        );
      }
      await first;
      expect(container.read(sendProvider)['same'], same(replacement));
      expect(container.read(sendProvider)['same']!.status, SessionStatus.waiting);
      expect(sender.sessionAttemptIdentity('same'), same(newAttempt));
      expect(client.canceled, lateStatus == 200 ? ['old-remote'] : isEmpty);
      sender.cancelSession('same');
      expect(api.tokens.map((t) => t.canceled), [1, 1], reason: 'old finally must not remove the new prepare token');
      client.requests[1].complete(const PrepareUploadResult(statusCode: 204));
      await second;
      expect(container.read(sendProvider), isEmpty);
    });
  }
  test('presentation identity survives cancellation and distinguishes same-ID rapid replacement cancellation', () async {
    final first = start();
    final originalIdentity = sender.sessionAttemptIdentity('same');
    sender.cancelSessionByReceiver('same');
    expect(sender.sessionAttemptIdentity('same'), same(originalIdentity));
    final second = start();
    final replacementIdentity = sender.sessionAttemptIdentity('same');
    sender.cancelSessionByReceiver('same');
    expect(replacementIdentity, isNot(same(originalIdentity)));
    expect(sender.sessionAttemptIdentity('same'), same(replacementIdentity));
    client.requests[0].complete(const PrepareUploadResult(statusCode: 204));
    client.requests[1].complete(const PrepareUploadResult(statusCode: 204));
    await Future.wait([first, second]);
    expect(container.read(sendProvider)['same']!.status, SessionStatus.canceledByReceiver);
    expect(sender.sessionAttemptIdentity('same'), same(replacementIdentity));
    sender.closeSession('same');
    expect(sender.sessionAttemptIdentity('same'), isNull);
  });
  test('reusing a terminal ID clears obsolete file progress before its next preparation', () async {
    final first = start();
    client.requests[0].complete(const PrepareUploadResult(statusCode: 204));
    await first;
    final transfer = container.notifier(fileTransferProvider);
    transfer.setStatus(sessionId: 'same', fileId: 'obsolete', status: FileStatus.failed);
    final second = start();
    expect(transfer.getData()['same']!.keys, container.read(sendProvider)['same']!.files.keys);
    expect(transfer.getData()['same']!.containsKey('obsolete'), false);
    client.requests[1].complete(const PrepareUploadResult(statusCode: 204));
    await second;
    expect(container.read(sendProvider)['same']!.status, SessionStatus.finished);
  });
  test('an already active requested ID is rejected without replacing state or starting another request', () async {
    final first = start();
    final snapshot = container.read(sendProvider)['same'];
    await expectLater(start(), throwsStateError);
    expect(client.requests, hasLength(1));
    expect(container.read(sendProvider)['same'], same(snapshot));
    client.requests.single.complete(const PrepareUploadResult(statusCode: 204));
    await first;
    expect(container.read(sendProvider)['same']!.status, SessionStatus.finished);
  });
}
