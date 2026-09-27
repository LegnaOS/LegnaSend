import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/http_server.dart';
import 'package:localsend_isolates/src/task/server/receive_source_end_scope.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';

class _Web extends Fake implements WebParams {}

class _Server extends Fake implements RsHttpServer {
  final events = StreamController<RsServerEvent>();
  Future<void> Function()? stopping;
  int stops = 0;
  Future<String> Function()? snapshot;
  @override
  Future<String> webDownloadActivity() async => snapshot == null ? '[]' : await snapshot!();
  Future<int> Function()? lookupPort;
  @override
  Future<int> port() async => await (lookupPort?.call() ?? Future<int>.value(53317));
  @override
  Stream<RsServerEvent> listen() => events.stream;
  final identityReplies = <List<String?>>[];
  @override
  Future<bool> respondReceiveCacheIdentity({
    required String sessionId,
    required String fileId,
    required String attemptId,
    required String transactionId,
    String? error,
    String? recoveryTransactionId,
    String? recoveryIdentityJson,
    int? recoverySourceDescriptor,
  }) async {
    identityReplies.add([sessionId, fileId, attemptId, transactionId, error]);
    return true;
  }

  final sourceEndReplies = <(String, bool)>[];
  Future<bool> Function()? sourceEndCompletion;
  @override
  Future<bool> respondReceiveSourceEndScope({required String requestId, required bool granted}) async {
    sourceEndReplies.add((requestId, granted));
    return await (sourceEndCompletion?.call() ?? Future.value(true));
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopping?.call();
  }
}

class _Api extends RustLibApi {
  late Future<RsHttpServer> Function() start;
  int calls = 0;
  @override
  Future<RsHttpServer> crateApiServerStartServer({
    required int port,
    TlsConfig? tls,
    required String alias,
    required String version,
    String? deviceModel,
    DeviceType? deviceType,
    required String fingerprint,
    String? pin,
    required bool verifyChecksums,
    required WebParams web,
    String? showToken,
  }) {
    calls++;
    return start();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Stream<RsServerEvent>> _start(HttpServerService service) => service.start(
  port: 0,
  tls: null,
  alias: 'Fixture',
  version: '2.2',
  deviceModel: null,
  deviceType: null,
  fingerprint: 'fixture',
  pin: null,
  verifyChecksums: true,
  web: _Web(),
  showToken: null,
);
Future<void> _turns() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => api.calls = 0);
  test('identity response forwards exact binding only while native server exists', () async {
    final service = HttpServerService(), server = _Server();
    api.start = () async => server;
    await _start(service);
    expect(
      await service.respondReceiveCacheIdentity(
        sessionId: 'session',
        fileId: 'file',
        attemptId: 'attempt',
        transactionId: 'transaction',
        error: 'denied',
      ),
      true,
    );
    expect(server.identityReplies, [
      ['session', 'file', 'attempt', 'transaction', 'denied'],
    ]);
    await service.stop();
    expect(
      await service.respondReceiveCacheIdentity(
        sessionId: 'session',
        fileId: 'file',
        attemptId: 'attempt',
        transactionId: 'transaction',
        error: null,
      ),
      false,
    );
    expect(server.identityReplies.length, 1);
  });
  test('stop waits for pending native bind and leaves no resurrected server', () async {
    final service = HttpServerService(), server = _Server();
    final bind = Completer<RsHttpServer>();
    api.start = () => bind.future;
    final starting = _start(service);
    await _turns();
    var stopped = false;
    final stopping = service.stop().then((_) => stopped = true);
    await _turns();
    final premature = stopped;
    bind.complete(server);
    await starting;
    await stopping;
    expect(premature, false);
    expect(service.running, false);
    expect(server.stops, 1);
  });
  test('stopWithActivity reads the final snapshot from the stopped original handle', () async {
    final service = HttpServerService(), server = _Server();
    api.start = () async => server;
    await _start(service);
    var finalState = 'active';
    server.stopping = () async => finalState = 'succeeded';
    server.snapshot = () async => finalState;
    expect(await service.stopWithActivity(), 'succeeded');
    expect(service.running, false);
    expect(server.stops, 1);
  });
  test('stopWithActivity tolerates unavailable final observation without inventing a result', () async {
    final service = HttpServerService(), server = _Server();
    api.start = () async => server;
    await _start(service);
    server.snapshot = () async => throw StateError('observation unavailable');
    expect(await service.stopWithActivity(), isNull);
    expect(service.running, false);
    expect(server.stops, 1);
  });
  test('one stopped observation handle survives failed start and is replaced only on successful start', () async {
    final service = HttpServerService(), old = _Server(), replacement = _Server();
    var outcome = 'publishing';
    old.snapshot = () async => outcome;
    replacement.snapshot = () async => 'shared-new-and-old';
    api.start = () async => old;
    await _start(service);
    expect(await service.stopWithActivity(), 'publishing');
    outcome = 'succeeded';
    expect(await service.webDownloadActivity(), 'succeeded');
    api.start = () async => throw StateError('bind failed');
    await expectLater(_start(service), throwsStateError);
    expect(await service.webDownloadActivity(), 'succeeded');
    expect(service.running, false);
    expect(() => service.cancelWebDownload('old'), throwsStateError);
    api.start = () async => replacement;
    await _start(service);
    expect(await service.webDownloadActivity(), 'shared-new-and-old');
    await service.stop();
    expect(await service.webDownloadActivity(), 'shared-new-and-old');
    expect(old.stops, 1);
    expect(replacement.stops, 1);
  });
  test('stopped observation read failure is retryable without any listener', () async {
    final service = HttpServerService(), server = _Server();
    api.start = () async => server;
    await _start(service);
    server.snapshot = () async => throw StateError('temporary bridge error');
    expect(await service.stopWithActivity(), isNull);
    server.snapshot = () async => 'late-success';
    expect(await service.webDownloadActivity(), 'late-success');
    expect(service.running, false);
    expect(await service.stopWithActivity(), 'late-success');
    expect(server.stops, 1);
  });
  test('never-started observation is a valid empty history', () async {
    final service = HttpServerService();
    expect(await service.webDownloadActivity(), '[]');
    expect(await service.stopWithActivity(), '[]');
  });
  test('concurrent starts create exactly one native server', () async {
    final service = HttpServerService(), server = _Server();
    final bind = Completer<RsHttpServer>();
    api.start = () => bind.future;
    final first = _start(service);
    final second = _start(service);
    final rejected = expectLater(second, throwsStateError);
    await _turns();
    final callsWhileBinding = api.calls;
    bind.complete(server);
    await first;
    await rejected;
    expect(callsWhileBinding, 1);
    await service.stop();
  });
  test('replacement bind waits until the old native listener releases its port', () async {
    final service = HttpServerService(), old = _Server(), next = _Server();
    final release = Completer<void>();
    old.stopping = () => release.future;
    api.start = () async => api.calls == 1 ? old : next;
    await _start(service);
    final stopping = service.stop();
    await _turns();
    final starting = _start(service);
    await _turns();
    final callsBeforeRelease = api.calls;
    release.complete();
    await stopping;
    await starting;
    expect(callsBeforeRelease, 1);
    expect(api.calls, 2);
    expect(service.running, true);
    await service.stop();
  });
  test('native startup failure does not poison the next lifecycle operation', () async {
    final service = HttpServerService(), server = _Server();
    api.start = () async {
      if (api.calls == 1) throw StateError('Port occupied');
      return server;
    };
    final first = expectLater(_start(service), throwsStateError);
    final next = _start(service);
    await first;
    await next;
    expect(service.running, true);
    await service.stop();
    expect(server.stops, 1);
  });
  test('old event loop ownership and cleanup cannot clear a replacement listener', () async {
    final service = HttpServerService(), old = _Server(), next = _Server();
    api.start = () async => api.calls == 1 ? old : next;
    final first = await _start(service);
    expect(service.ownsEvents(first), true);
    await service.stop();
    final replacement = await _start(service);
    expect(service.ownsEvents(first), false);
    expect(service.ownsEvents(replacement), true);
    await service.stop(expectedEvents: first);
    expect(service.running, true);
    expect(next.stops, 0);
    await service.stop(expectedEvents: replacement);
    expect(next.stops, 1);
  });
  for (final fails in [false, true]) {
    test('late port lookup after replacement is discarded (fails=$fails)', () async {
      final service = HttpServerService(), old = _Server(), next = _Server();
      final port = Completer<int>();
      old.lookupPort = () => port.future;
      api.start = () async => api.calls == 1 ? old : next;
      final first = await _start(service);
      final reading = service.boundPortFor(first);
      await service.stop();
      final replacement = await _start(service);
      if (fails) {
        port.completeError(StateError('Old listener closed'));
      } else {
        port.complete(53318);
      }
      expect(await reading, isNull);
      expect(await service.boundPortFor(replacement), 53317);
      await service.stop();
    });
  }
  test('source-end responder remains on original server while worker outlives replacement', () async {
    final service = HttpServerService(), old = _Server(), replacement = _Server();
    api.start = () async => api.calls == 1 ? old : replacement;
    final original = await _start(service);
    final completed = Completer<bool>();
    old.sourceEndCompletion = () => completed.future;
    final reply = service.receiveSourceEndScopeResponder(original);
    var releases = 0;
    final handling = ReceiveSourceEndScopeHandler(
      reply: reply,
      supported: true,
      isCurrent: () => service.ownsEvents(original),
      acquire: (path) async => IosReceiveScopeLease(
        leaseId: '19a3b3f0-141b-4c41-b421-2f68a0e929d3',
        path: path,
        release: (_) async {
          releases++;
        },
      ),
    ).handle('original-request', '/provider/folder');
    await _turns();
    expect(old.sourceEndReplies, [('original-request', true)]);
    await service.stop();
    await _start(service);
    expect(releases, 0);
    expect(replacement.sourceEndReplies, isEmpty);
    expect(() => service.receiveSourceEndScopeResponder(original), throwsStateError);
    completed.complete(true);
    await handling;
    expect(releases, 1);
    expect(service.running, true);
    expect(replacement.sourceEndReplies, isEmpty);
    await service.stop();
  });
  test('late source-end acquisition denies to captured stopped server, never its replacement', () async {
    final service = HttpServerService(), old = _Server(), replacement = _Server();
    api.start = () async => api.calls == 1 ? old : replacement;
    final original = await _start(service);
    final acquisition = Completer<IosReceiveScopeLease?>();
    var releases = 0;
    final handling = ReceiveSourceEndScopeHandler(
      reply: service.receiveSourceEndScopeResponder(original),
      supported: true,
      isCurrent: () => service.ownsEvents(original),
      acquire: (_) => acquisition.future,
    ).handle('late-request', '/provider/folder');
    await service.stop();
    await _start(service);
    acquisition.complete(
      IosReceiveScopeLease(
        leaseId: '19a3b3f0-141b-4c41-b421-2f68a0e929d3',
        path: '/provider/folder',
        release: (_) async {
          releases++;
        },
      ),
    );
    await handling;
    expect(old.sourceEndReplies, [('late-request', false)]);
    expect(replacement.sourceEndReplies, isEmpty);
    expect(releases, 1);
    await service.stop();
  });
}
