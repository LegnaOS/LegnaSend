import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/network_signals.dart';
import 'package:refena_flutter/refena_flutter.dart';
import '../../mocks.mocks.dart';

const local = LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.4', prefixLength: 24, wifi: true);
const tunnel = LocalNetworkAddress(interfaceName: 'utun4', address: '198.18.0.1', prefixLength: 30, wifi: true);
const idle = LocalNetworkAddress(interfaceName: 'utun3', address: 'fe80::1234', prefixLength: 64);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('tunnel evidence excludes link-local-only Apple interfaces and survives filtering', () {
    expect(local.isTunnel, isFalse);
    expect(tunnel.isTunnel, isTrue);
    expect(tunnel.label, 'utun4');
    expect(idle.isTunnel, isTrue);
    expect(idle.hasNonLinkLocalAddress, isFalse);
    expect(composeNetworkState(all: [local, idle], signals: const NetworkSignals()).hasNetworkOverlay, isFalse);
    final snapshot = composeNetworkState(all: [local, idle, tunnel], signals: const NetworkSignals(), blacklist: ['198.18.0.1']);
    expect(snapshot.tunnelInterfaces, ['utun4']);
    expect(snapshot.addresses, [local, idle]);
    expect(snapshot.localIps, ['192.168.1.4']);
    expect(snapshot.vpnKnown, isFalse);
  });

  test('VPN on/off refreshes discovery only; unchanged/proxy-only signals do not', () async {
    final settingsContainer = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
    addTearDown(settingsContainer.disposeContainer);
    var snapshot = composeNetworkState(all: [local], signals: const NetworkSignals(vpnKnown: true, proxyKnown: true));
    var discovery = 0;
    final service = ReduxNotifier.test(
      redux: LocalIpService(
        settingsContainer.notifier(settingsProvider),
        monitor: false,
        snapshotLoader: (_, _) async => snapshot,
        onNetworkChanged: () => discovery++,
      ),
    );
    addTearDown(service.notifier.dispose);
    await service.dispatchAsync(FetchLocalIpAction());
    expect(discovery, 0);
    snapshot = composeNetworkState(all: [local, tunnel], signals: const NetworkSignals(vpnKnown: true, vpnDetected: true));
    await service.dispatchAsync(FetchLocalIpAction());
    expect(service.state.vpnDetected, isTrue);
    expect(discovery, 1);
    await service.dispatchAsync(FetchLocalIpAction());
    expect(discovery, 1);
    snapshot = snapshot.copyWith(proxyEnabled: true, proxyKnown: true);
    await service.dispatchAsync(FetchLocalIpAction());
    expect(service.state.proxyEnabled, isTrue);
    expect(discovery, 1);
    snapshot = composeNetworkState(all: [local], signals: const NetworkSignals(vpnKnown: true));
    await service.dispatchAsync(FetchLocalIpAction());
    expect(service.state.hasNetworkOverlay, isFalse);
    expect(discovery, 2);
  });

  test('snapshots coalesce identical filters but never overwrite newer filter results', () async {
    final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
    addTearDown(container.disposeContainer);
    final requests = <Completer<NetworkState>>[];
    final service = LocalIpService(
      container.notifier(settingsProvider),
      monitor: false,
      snapshotLoader: (_, _) {
        final next = Completer<NetworkState>();
        requests.add(next);
        return next.future;
      },
    );
    final first = service.snapshot(null, null);
    final same = service.snapshot(null, null);
    final filtered = service.snapshot(['192.168.1.4'], null);
    expect(requests.length, 2);
    final newer = composeNetworkState(all: [local], signals: const NetworkSignals());
    requests[1].complete(newer);
    expect(await filtered, newer);
    final old = composeNetworkState(all: [tunnel], signals: const NetworkSignals());
    requests[0].complete(old);
    expect(await first, old);
    expect(await same, old);
  });

  test('discovery failure does not hide changed VPN evidence', () async {
    final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
    addTearDown(container.disposeContainer);
    final service = ReduxNotifier.test(
      redux: LocalIpService(
        container.notifier(settingsProvider),
        monitor: false,
        snapshotLoader: (_, _) async => composeNetworkState(all: [local, tunnel], signals: const NetworkSignals()),
        onNetworkChanged: () => throw StateError('discovery not ready'),
      ),
      initialState: composeNetworkState(all: [local], signals: const NetworkSignals()),
    );
    addTearDown(service.notifier.dispose);
    await service.dispatchAsync(FetchLocalIpAction());
    expect(service.state.tunnelInterfaces, ['utun4']);
  });

  test('native signals expose booleans and retain unknown when plugin is unavailable', () async {
    const channel = MethodChannel('main-delegate-channel');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'networkSignals');
      return {'vpnKnown': false, 'proxyKnown': true, 'proxyEnabled': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final active = await readNetworkSignals();
    expect(active.proxyKnown, isTrue);
    expect(active.proxyEnabled, isTrue);
    expect(active.vpnKnown, isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'unavailable'));
    final unknown = await readNetworkSignals();
    expect(unknown.proxyKnown, isFalse);
    expect(unknown.vpnKnown, isFalse);
  }, skip: !Platform.isMacOS);

  test('stale web lifecycle requests do not read settings or touch the isolate', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final server = container.notifier(serverProvider);
    expect(await server.stopWebShare(expectedGeneration: server.generation + 1), isFalse);
    expect(await server.updateWebSettings(expectedGeneration: server.generation + 1, https: false), isFalse);
    expect(await server.restartServer(alias: 'stale', port: 53317, https: false, expectedGeneration: server.generation + 1), isNull);
    expect(server.generation, 0);
  });
}
