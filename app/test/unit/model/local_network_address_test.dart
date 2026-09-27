import 'package:localsend_app/model/local_network_address.dart';
import 'package:test/test.dart';

void main() {
  test('CIDR uses the actual mask rather than three address octets', () {
    const a = LocalNetworkAddress(interfaceName: 'en7', address: '192.168.21.8', prefixLength: 23);
    expect(a.cidr, '192.168.20.0/23');
    expect(a.containsHost('192.168.20.9'), isTrue);
    expect(a.containsHost('192.168.22.9'), isFalse);
    const b = LocalNetworkAddress(interfaceName: 'en0', address: '10.21.4.8', prefixLength: 16);
    expect(b.cidr, '10.21.0.0/16');
    expect(b.containsHost('10.21.240.9'), isTrue);
  });
  test('unknown and invalid prefixes never invent a network', () {
    for (final prefix in [null, -1, 33]) {
      final a = LocalNetworkAddress(interfaceName: 'en7', address: '192.168.21.8', prefixLength: prefix);
      expect(a.cidr, isNull);
      expect(a.containsHost('192.168.21.9'), isFalse);
    }
    const any = LocalNetworkAddress(interfaceName: 'vpn', address: '10.0.0.1', prefixLength: 0);
    expect(any.containsHost('192.168.0.1'), isFalse);
  });
  test('IPv6 scope disambiguates otherwise identical link local networks', () {
    const a = LocalNetworkAddress(interfaceName: 'en7', interfaceIndex: 7, address: 'fe80::1', prefixLength: 64);
    expect(a.cidr, 'fe80::/64');
    expect(a.containsHost('fe80::2%7'), isTrue);
    expect(a.containsHost('fe80::2%en7'), isTrue);
    expect(a.containsHost('fe80::2%8'), isFalse);
    expect(a.containsHost('192.168.0.1'), isFalse);
  });
  test('overlapping networks retain both matches without asserting a route', () {
    final interfaces = [
      for (final name in ['en0', 'en7']) LocalNetworkAddress(interfaceName: name, address: '10.0.0.1', prefixLength: 24),
    ];
    expect(interfaces.where((a) => a.containsHost('10.0.0.2')).length, 2);
  });
}
