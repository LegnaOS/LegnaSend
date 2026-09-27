import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';

part 'local_network_address.mapper.dart';

@MappableClass()
class LocalNetworkAddress with LocalNetworkAddressMappable {
  final String interfaceName;
  final int? interfaceIndex;
  final String address;
  final int? prefixLength;
  final bool wifi;
  final String? androidNetworkHandle;
  final String? androidNetworkEpoch;
  final bool? androidVpn;
  final bool cellular;

  const LocalNetworkAddress({
    required this.interfaceName,
    this.interfaceIndex,
    required this.address,
    this.prefixLength,
    this.wifi = false,
    this.androidNetworkHandle,
    this.androidNetworkEpoch,
    this.androidVpn,
    this.cellular = false,
  });

  /// Android system transport evidence when available; otherwise an interface-name
  /// hint only. Neither proves the actual path of a connection.
  bool get isTunnel =>
      androidVpn ??
      (RegExp(r'^(utun|tun|tap|ppp|wg|ipsec|tailscale|zerotier|zt)[0-9_.-]*$', caseSensitive: false).hasMatch(interfaceName) ||
          RegExp(r'(^|[\s_-])(vpn|wireguard|wintun|tailscale|zerotier|clash|mihomo)([\s_-]|$)', caseSensitive: false).hasMatch(interfaceName));

  bool get hasNonLinkLocalAddress {
    final ip = InternetAddress.tryParse(address.split('%').first);
    return ip != null && !ip.isLoopback && !ip.isLinkLocal && ip.rawAddress.any((byte) => byte != 0);
  }

  bool get isIpv6 => address.contains(':');
  String get label => wifi && !isTunnel ? 'Wi-Fi · $interfaceName' : interfaceName;

  String? get cidr {
    final ip = InternetAddress.tryParse(address);
    final prefix = prefixLength;
    if (ip == null || prefix == null || prefix < 0 || prefix > ip.rawAddress.length * 8) return null;
    final bytes = ip.rawAddress;
    for (var i = 0; i < bytes.length; i++) {
      final bits = (prefix - i * 8).clamp(0, 8);
      bytes[i] &= (0xff << (8 - bits)) & 0xff;
    }
    return '${InternetAddress.fromRawAddress(bytes).address}/$prefix';
  }

  /// A subnet match is not proof of the OS route, especially with overlapping interfaces.
  bool containsHost(String host) {
    final parts = host.split('%');
    if (parts.length > 1 && parts[1] != interfaceIndex?.toString() && parts[1] != interfaceName) return false;
    final peer = InternetAddress.tryParse(parts.first);
    final local = InternetAddress.tryParse(address);
    final prefix = prefixLength;
    if (peer == null || local == null || peer.type != local.type || prefix == null || prefix <= 0 || prefix > local.rawAddress.length * 8) {
      return false;
    }
    final a = local.rawAddress;
    final b = peer.rawAddress;
    for (var i = 0; i < a.length; i++) {
      final bits = (prefix - i * 8).clamp(0, 8);
      final mask = (0xff << (8 - bits)) & 0xff;
      if ((a[i] & mask) != (b[i] & mask)) return false;
    }
    return true;
  }
}
