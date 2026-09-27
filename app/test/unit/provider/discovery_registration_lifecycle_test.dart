import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import '../../mocks.mocks.dart';

class _Isolates extends Fake implements IsolateController {}

void main() {
  test('clear invalidates pending registration; newer merged channels win', () async {
    final favorite = FavoritesService(MockPersistenceService());
    ReduxNotifier.test(redux: favorite, initialState: favorite.init());
    final service = ReduxNotifier.test(
      redux: NearbyDevicesService(isolateController: _Isolates(), favoriteService: favorite, discoveryLogs: DiscoveryLogger()),
    );
    const a = HttpChannel(host: '192.0.2.1', port: 53317, https: false);
    const b = HttpChannel(host: 'fe80::1%3', port: 53317, https: true);
    final old = Device.empty.copyWith(ip: a.host, fingerprint: 'same', channels: [a]);
    final pending = service.dispatchAsync(RegisterDeviceAction(old));
    await Future<void>.microtask(() {});
    service.dispatch(ClearFoundDevicesAction());
    await pending;
    expect(service.state.devices, isEmpty);
    final first = service.dispatchAsync(RegisterDeviceAction(old));
    final second = service.dispatchAsync(RegisterDeviceAction(old.copyWith(channels: [a, b])));
    await Future.wait([first, second]);
    expect(service.state.devices['same']!.channels, [a, b]);
  });
}
