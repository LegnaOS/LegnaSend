import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/util/network/device_membership.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';

void main() {
  const physical = LocalNetworkAddress(interfaceName: 'en0', interfaceIndex: 4, address: '192.168.1.2', prefixLength: 24);
  const vpn = LocalNetworkAddress(interfaceName: 'utun0', interfaceIndex: 7, address: '192.168.1.3', prefixLength: 24);
  test('overlapping physical and tunnel subnets retain both evidence paths without claiming a route', () {
    final device = Device.empty.copyWith(
      ip: '192.168.1.9',
      channels: [const HttpChannel(host: '192.168.1.9', port: 53317, https: false)],
    );
    final result = deviceNetworkMemberships(device, [physical, vpn]);
    expect(result, hasLength(1));
    expect(result.single.overlapping, true);
    expect(result.single.matches, [physical, vpn]);
    expect(deviceMatchesNetwork(device, 'local', [physical, vpn]), true);
    expect(deviceMatchesNetwork(device, 'tunnel', [physical, vpn]), true);
    expect(deviceNetworkMemberships(device, [physical]).single.overlapping, false);
  });
  test('unconfirmed separate entry stays unknown while another matches a subnet', () {
    final device = Device.empty.copyWith(
      ip: '192.168.1.9',
      channels: [const HttpChannel(host: '203.0.113.4', port: 53317, https: true)],
    );
    final result = deviceNetworkMemberships(device, [physical]);
    expect(result.map((e) => e.unknown), [true, false]);
    expect(deviceMatchesNetwork(device, 'routed', [physical]), true);
  });
  test('IPv6 link-local scope limits evidence to the matching interface', () {
    const a = LocalNetworkAddress(interfaceName: 'en0', interfaceIndex: 4, address: 'fe80::1', prefixLength: 64);
    const b = LocalNetworkAddress(interfaceName: 'en1', interfaceIndex: 5, address: 'fe80::2', prefixLength: 64);
    final device = Device.empty.copyWith(ip: 'fe80::9%4');
    final result = deviceNetworkMemberships(device, [a, b]);
    expect(result.single.matches, [a]);
    expect(result.single.overlapping, false);
  });
}
