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
  bool disposed = false;
  void dispose() {
    if (!disposed) {
      disposed = true;
      container.disposeContainer();
    }
  }

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
      if (!disposed) await server.stopServer();
      for (final stream in streams) {
        await stream.close();
      }
      dispose();
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
  test('dispose rejects startup waiting for Started and cancels its owned subscription', () async {
    final f = _Fixture();
    f.onStart = (_, _) {};
    final starting = f.start();
    final rejected = expectLater(starting, throwsStateError);
    await _until(() => f.streams.isNotEmpty);
    expect(f.streams.single.hasListener, true);
    f.dispose();
    await rejected.timeout(const Duration(seconds: 2));
    expect(f.streams.single.hasListener, false);
    f.streams.single.add(HttpServerStartedEvent(53001));
    await Future<void>.delayed(Duration.zero);
    expect(f.streams, hasLength(1));
  });
  test('dispose immediately after Started acknowledgement prevents post-await state publication', () async {
    final f = _Fixture();
    f.onStart = (stream, _) {
      stream.add(HttpServerStartedEvent(53001));
      f.dispose();
    };
    await expectLater(f.start(), throwsStateError).timeout(const Duration(seconds: 2));
    expect(f.disposed, true);
    expect(f.streams.single.hasListener, false);
  });
  test('a queued start after disposed pending startup rejects without binding another listener', () async {
    final f = _Fixture();
    f.onStart = (_, _) {};
    final first = f.start(), second = f.start();
    final rejected = Future.wait([expectLater(first, throwsStateError), expectLater(second, throwsStateError)]);
    await _until(() => f.streams.isNotEmpty);
    f.dispose();
    await rejected.timeout(const Duration(seconds: 2));
    expect(f.streams, hasLength(1));
    expect(f.streams.single.hasListener, false);
    await expectLater(f.start(), throwsStateError);
  });
}
