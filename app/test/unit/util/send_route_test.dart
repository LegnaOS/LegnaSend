import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:test/test.dart';

const lan = HttpChannel(host: '192.168.1.9', port: 53317, https: false);
const vpn = HttpChannel(host: '10.8.0.9', port: 53318, https: true);
final peer = Device.empty.copyWith(fingerprint: 'peer', ip: lan.host, port: lan.port, https: lan.https, channels: [lan, vpn]);
const addresses = [
  LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.2', prefixLength: 24, wifi: true),
  LocalNetworkAddress(interfaceName: 'utun1', address: '10.8.0.2', prefixLength: 24),
];

void main() {
  test('source selection requires the same interface and current IP, never another adapter', () {
    const route = LocalSendRoute(interfaceName: 'en0', localAddress: '192.168.1.2');
    validateLocalSendRoute(null, []);
    validateLocalSendRoute(route, addresses);
    expect(() => validateLocalSendRoute(route, []), throwsA(isA<SelectedLocalRouteUnavailable>()));
    expect(
      () => validateLocalSendRoute(route, [const LocalNetworkAddress(interfaceName: 'en1', address: '192.168.1.2')]),
      throwsA(isA<SelectedLocalRouteUnavailable>()),
    );
    expect(
      () => validateLocalSendRoute(route, [const LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.3')]),
      throwsA(isA<SelectedLocalRouteUnavailable>()),
    );
    expect(localSendRouteMatchesHost(route, '2001:db8::2'), isFalse);
    expect(localSendRouteMatchesHost(route, lan.host), isTrue);
  });
  test('source IPv6 spelling is normalized but stale zone literals are not accepted', () {
    const route = LocalSendRoute(interfaceName: 'en0', localAddress: '2001:db8:0:0:0:0:0:1');
    expect(localSendRouteAvailable(route, [const LocalNetworkAddress(interfaceName: 'en0', address: '2001:db8::1')]), isTrue);
    expect(localSendRouteMatchesHost(route, 'fe80::9%3'), isTrue);
    expect(localSendRouteAvailable(const LocalSendRoute(interfaceName: 'en0', localAddress: 'fe80::1%3'), addresses), isFalse);
  });

  test('channels include legacy primary endpoint and deduplicate exact matches', () {
    expect(deviceHttpChannels(peer), [lan, vpn]);
    expect(deviceHttpChannels(peer.copyWith(channels: [])), [lan]);
    expect(deviceHttpChannels(Device.empty), isEmpty);
  });
  test('automatic selection preserves the latest discovery primary', () {
    final latest = peer.copyWith(ip: vpn.host, port: vpn.port, https: true, channels: [vpn, lan]);
    expect(resolveSendTarget(peer, latest, null), same(latest));
    expect(resolveSendTarget(peer, null, null), same(peer));
  });
  test('explicit entry point survives discovery reordering including TLS and port', () {
    final latest = peer.copyWith(ip: vpn.host, port: vpn.port, https: true, channels: [vpn, lan]);
    final pinned = resolveSendTarget(peer, latest, lan);
    expect(pinned.ip, lan.host);
    expect(pinned.port, lan.port);
    expect(pinned.https, isFalse);
    expect(pinned.channels, [lan]);
    expect(pinned.fingerprint, peer.fingerprint);
    expect(resolveSendTarget(peer, null, vpn).ip, vpn.host);
  });
  test('removed endpoint or changed TLS or port fails without falling back', () {
    for (final replacement in [vpn, lan.copyWith(port: 443), lan.copyWith(https: true)]) {
      final latest = peer.copyWith(ip: replacement.host, port: replacement.port, https: replacement.https, channels: [replacement]);
      expect(() => resolveSendTarget(peer, latest, lan), throwsA(isA<SelectedChannelUnavailable>()));
    }
  });
  test('multi-homed devices match every evidenced subnet without route claims', () {
    expect(deviceMatchesNetwork(peer, 'all', addresses), isTrue);
    expect(deviceMatchesNetwork(peer, 'local', addresses), isTrue);
    expect(deviceMatchesNetwork(peer, 'tunnel', addresses), isTrue);
    expect(deviceMatchesNetwork(peer, 'routed', addresses), isFalse);
    for (final address in addresses) {
      expect(deviceMatchesNetwork(peer, networkFilterKey(address), addresses), isTrue);
    }
    expect(deviceMatchesNetwork(peer, networkFilterKey(addresses.first), []), isFalse);
  });
  test('routed and signaling-only entries stay discoverable in unknown filter', () {
    expect(deviceMatchesNetwork(peer.copyWith(ip: '203.0.113.1', channels: []), 'routed', addresses), isTrue);
    expect(deviceMatchesNetwork(Device.empty, 'routed', addresses), isTrue);
    expect(deviceMatchesNetwork(Device.empty, 'local', addresses), isFalse);
  });
  test('IPv6 link-local scope is respected by interface filters', () {
    const first = LocalNetworkAddress(interfaceName: 'en0', interfaceIndex: 3, address: 'fe80::1', prefixLength: 64);
    const second = LocalNetworkAddress(interfaceName: 'en1', interfaceIndex: 4, address: 'fe80::2', prefixLength: 64);
    final scoped = peer.copyWith(ip: 'fe80::9%3', channels: []);
    expect(deviceMatchesNetwork(scoped, networkFilterKey(first), [first, second]), isTrue);
    expect(deviceMatchesNetwork(scoped, networkFilterKey(second), [first, second]), isFalse);
    expect(httpChannelLabel(const HttpChannel(host: 'fe80::9%3', port: 80, https: false)), 'HTTP · [fe80::9%3]:80');
  });
}
