import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../mocks.mocks.dart';

class _Fixture {
  final streams = <StreamController<HttpServerEvent>>[];
  late final RefenaContainer container;
  late final ServerService server;
  int stops = 0;
  Future<void> Function()? stop;
  Future<Socket> Function(int)? probe;
  void Function(StreamController<HttpServerEvent>, int)? onStart;

  _Fixture() {
    server = ServerService(
      startListener: (_) {
        final stream = StreamController<HttpServerEvent>(sync: true);
        streams.add(stream);
        scheduleMicrotask(() => onStart?.call(stream, streams.length));
        return stream.stream;
      },
      stopListener: () async {
        stops++;
        await stop?.call();
      },
      probeListener: (port) => probe!(port),
    );
    container = RefenaContainer(
      overrides: [
        serverProvider.overrideWithNotifier((_) => server),
        settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
        webTransferActivityProvider.overrideWithNotifier((_) => WebTransferActivityNotifier(loadSnapshot: () async => '[]')),
        parentIsolateProvider.overrideWithNotifier(
          (_) => IsolateController(
            initialState: ParentIsolateState.initial(
              SyncState(
                rootIsolateToken: Object(),
                securityContext: const StoredSecurityContext(privateKey: 'key', publicKey: 'public', certificate: 'cert', certificateHash: 'hash'),
                deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Fixture', androidSdkInt: null),
                alias: 'Fixture',
                port: 53317,
                discoveryPort: 53317,
                networkWhitelist: null,
                networkBlacklist: null,
                protocol: ProtocolType.http,
                multicastGroup: '224.0.0.167',
                discoveryTimeout: 1000,
                serverRunning: false,
                download: false,
              ),
            ),
          ),
        ),
      ],
    );
    container.read(serverProvider);
    addTearDown(() async {
      stop = null;
      await server.stopServer();
      for (final stream in streams) {
        await stream.close();
      }
      container.disposeContainer();
    });
    onStart = (stream, index) => stream.add(HttpServerStartedEvent(53000 + index));
  }

  Future<void> start() async => server.startServer(alias: 'Fixture', port: 0, https: false);
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Listener transition did not complete');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stream ending before Started rejects startup and the next queued start succeeds', () async {
    final f = _Fixture();
    f.onStart = (stream, index) {
      if (index == 1) {
        unawaited(stream.close());
      } else {
        stream.add(HttpServerStartedEvent(53000 + index));
      }
    };
    final first = f.start();
    final rejected = expectLater(first, throwsStateError);
    final second = f.start();
    await rejected;
    await second;
    expect(f.server.state?.port, 53002);
    expect(f.streams.length, 2);
    expect(f.container.read(parentIsolateProvider).syncState.serverRunning, isTrue);
  });

  test('stop unpublishes state before awaiting shutdown; failed stop does not poison restart', () async {
    final f = _Fixture();
    await f.start();
    final gate = Completer<void>();
    f.stop = () => gate.future;
    final stopping = f.server.stopServer();
    final rejected = expectLater(stopping, throwsStateError);
    await _until(() => f.stops == 1);
    expect(f.server.state, isNull);
    expect(f.container.read(parentIsolateProvider).syncState.serverRunning, isFalse);
    gate.completeError(StateError('Listener already gone'));
    await rejected;
    f.stop = null;
    await f.start();
    expect(f.server.state?.port, 53002);
  });

  test('late failed health probe never restarts a user-replaced listener', () async {
    final f = _Fixture();
    await f.start();
    final probe = Completer<Socket>();
    f.probe = (_) => probe.future;
    final checking = f.server.ensureRunning();
    await f.server.restartServer(alias: 'Replacement', port: 0, https: false);
    expect(f.server.state?.alias, 'Replacement');
    probe.completeError(const SocketException('Old socket closed'));
    await checking;
    expect(f.streams, hasLength(2));
    expect(f.stops, 1);
    expect(f.server.state?.alias, 'Replacement');
  });

  test('listener failure plus stream end schedules only one replacement', () async {
    final f = _Fixture();
    await f.start();
    f.streams.first.add(HttpServerListenerFailedEvent(error: 'socket reclaimed'));
    await f.streams.first.close();
    await _until(() => f.server.state?.port == 53002);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(f.streams, hasLength(2));
    expect(f.stops, 1);
  });

  test('unexpected stream end after startup recovers without losing listener configuration', () async {
    final f = _Fixture();
    await f.server.startServer(alias: 'Preserved', port: 0, https: false);
    await f.streams.first.close();
    await _until(() => f.server.state?.port == 53002);
    expect(f.server.state?.alias, 'Preserved');
    expect(f.server.state?.https, isFalse);
    expect(f.stops, 1);
  });

  test('immediate failure after Started runs only after state publication', () async {
    final f = _Fixture();
    f.onStart = (stream, index) {
      stream.add(HttpServerStartedEvent(53000 + index));
      if (index == 1) stream.add(HttpServerListenerFailedEvent(error: 'immediate failure'));
    };
    await f.start();
    await _until(() => f.server.state?.port == 53002);
    expect(f.streams, hasLength(2));
  });
  test('startup stream error suppresses synchronous trailing activity events', () async {
    final f = _Fixture();
    f.onStart = (stream, _) {
      stream.addError(StateError('Startup failed'));
      stream.add(HttpServerWebDownloadActivityEvent('not a valid snapshot'));
    };
    await expectLater(f.start(), throwsStateError);
    expect(f.server.state, isNull);
  });
}
