import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';

String sendDeviceKey(Device device) => device.fingerprint.isNotEmpty ? device.fingerprint : '${device.ip}:${device.port}:${device.https}';

/// HTTP entry points, not an OS interface binding or proof of a VPN bypass.
List<HttpChannel> deviceHttpChannels(Device device) => {
  ...device.channels.whereType<HttpChannel>(),
  if (device.ip != null) HttpChannel(host: device.ip!, port: device.port, https: device.https),
}.toList(growable: false);

String httpChannelLabel(HttpChannel channel) =>
    '${channel.https ? 'HTTPS' : 'HTTP'} · ${channel.host.contains(':') ? '[${channel.host}]' : channel.host}:${channel.port}';

class SelectedChannelUnavailable implements Exception {
  const SelectedChannelUnavailable();
  @override
  String toString() => 'selected-channel-unavailable';
}

/// An explicit entry point survives discovery reordering and retries. A known
/// replacement must still advertise that exact host, port and TLS mode. If
/// discovery has no current record, dial the pinned endpoint, never a fallback.
Device resolveSendTarget(Device original, Device? discovered, HttpChannel? selected) {
  final current = discovered ?? original;
  if (selected == null) return current;
  if (!deviceHttpChannels(current).contains(selected)) throw const SelectedChannelUnavailable();
  return current.copyWith(ip: selected.host, port: selected.port, https: selected.https, channels: [selected]);
}

String networkFilterKey(LocalNetworkAddress address) => 'interface:${address.interfaceName}:${address.interfaceIndex}:${address.cidr}';

/// Filters show subnet evidence only; unknown routes remain separately visible.
bool deviceMatchesNetwork(Device device, String filter, List<LocalNetworkAddress> addresses) {
  if (filter == 'all') return true;
  final channels = deviceHttpChannels(device);
  final matches = addresses.where((address) => channels.any((channel) => address.containsHost(channel.host)));
  return switch (filter) {
    'local' => matches.any((address) => !address.isTunnel),
    'tunnel' => matches.any((address) => address.isTunnel),
    'routed' => channels.isEmpty || channels.any((channel) => !addresses.any((address) => address.containsHost(channel.host))),
    _ => matches.any((address) => networkFilterKey(address) == filter),
  };
}

class SelectedLocalRouteUnavailable implements Exception {
  const SelectedLocalRouteUnavailable();
  @override
  String toString() => 'selected-local-route-unavailable';
}

String localSendRouteLabel(LocalSendRoute route) => '${route.interfaceName} · ${route.localAddress}';

bool localSendRouteAvailable(LocalSendRoute route, List<LocalNetworkAddress> addresses) {
  final source = InternetAddress.tryParse(route.localAddress);
  if (source == null || route.localAddress.contains('%')) return false;
  return addresses.any(
    (address) =>
        address.interfaceName == route.interfaceName &&
        (route.androidNetworkHandle == null ||
            (address.androidNetworkHandle == route.androidNetworkHandle && address.androidNetworkEpoch == route.androidNetworkEpoch)) &&
        listEquals(InternetAddress.tryParse(address.address.split('%').first)?.rawAddress, source.rawAddress),
  );
}

/// UI snapshot guard only. Rust also rechecks the actual interface at client
/// creation and before each request, including requests on pooled connections.
void validateLocalSendRoute(LocalSendRoute? route, List<LocalNetworkAddress> addresses) {
  if (route != null && !localSendRouteAvailable(route, addresses)) throw const SelectedLocalRouteUnavailable();
}

bool localSendRouteMatchesHost(LocalSendRoute route, String? host) {
  final source = InternetAddress.tryParse(route.localAddress);
  if (source == null) return false;
  final target = host == null ? null : InternetAddress.tryParse(host.split('%').first);
  return target == null || target.type == source.type;
}
