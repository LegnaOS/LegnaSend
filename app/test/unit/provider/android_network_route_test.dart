import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/util/native/android_network_routes.dart';
import 'package:localsend_app/util/native/network_signals.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/local_send_route.dart';

const epoch = '11111111-1111-4111-8111-111111111111';
const lease = '22222222-2222-4222-8222-222222222222';
Map<String, Object> snapshot() => {
  'epoch': epoch,
  'revision': 1,
  'networks': [
    {
      'handle': '123',
      'lease': lease,
      'interfaceName': 'wlan0',
      'addresses': ['192.0.2.7', '2001:db8:0:0:0:0:0:7'],
      'vpn': false,
      'wifi': true,
      'cellular': false,
    },
  ],
};
void main() {
  test('system identities map to immutable routes and equivalent IPv6 text matches interface', () {
    final cache = AndroidNetworkSnapshotCache();
    final synced = <String?>[];
    final addresses = applyAndroidNetworkSnapshot(snapshot(), configure: synced.add, cache: cache);
    expect(jsonDecode(synced.single!)['networks'][0]['handle'], '123');
    final state = composeNetworkState(
      all: [const LocalNetworkAddress(interfaceName: 'wlan0', interfaceIndex: 7, address: '2001:db8::7', prefixLength: 64)],
      signals: NetworkSignals(androidNetworks: addresses),
    );
    expect(state.addresses.single.androidNetworkHandle, '123');
    final route = LocalSendRoute(
      interfaceName: 'wlan0',
      localAddress: '2001:db8::7',
      androidNetworkHandle: '123',
      androidNetworkEpoch: '$epoch:$lease',
    );
    expect(localSendRouteAvailable(route, state.addresses), isTrue);
    expect(
      localSendRouteAvailable(route, [state.addresses.single.copyWith(androidNetworkEpoch: '$epoch:33333333-3333-4333-8333-333333333333')]),
      isFalse,
    );
    expect(LocalSendRoute.fromJson(route.toJson()), route);
    expect(localSendRouteAvailable(route, [const LocalNetworkAddress(interfaceName: 'wlan0', address: '2001:db8::7')]), isFalse);
  });
  test('event shrink and polled late reply use one monotonic cache', () {
    final cache = AndroidNetworkSnapshotCache();
    final sent = <String?>[];
    expect(applyAndroidNetworkSnapshot(snapshot(), cache: cache, configure: sent.add), hasLength(2));
    expect(applyAndroidNetworkSnapshot({...snapshot(), 'revision': 2, 'networks': []}, cache: cache, configure: sent.add), isEmpty);
    expect(applyAndroidNetworkSnapshot(snapshot(), cache: cache, configure: sent.add), isEmpty);
    expect(sent, hasLength(2));
  });
  test('missing, zero or malformed system identities clear native registry instead of source fallback', () {
    final cache = AndroidNetworkSnapshotCache();
    final synced = <String?>[];
    expect(applyAndroidNetworkSnapshot(null, configure: synced.add, cache: cache), isEmpty);
    final input = snapshot();
    ((input['networks'] as List).single as Map)['handle'] = '0';
    expect(applyAndroidNetworkSnapshot(input, configure: synced.add, cache: cache), isEmpty);
    expect(synced, [null, null]);
    var clears = 0;
    expect(
      applyAndroidNetworkSnapshot(
        snapshot(),
        cache: cache,
        configure: (raw) {
          if (raw == null) {
            clears++;
          } else {
            throw StateError('native validation');
          }
        },
      ),
      isEmpty,
    );
    expect(clears, 1);
  });
}
