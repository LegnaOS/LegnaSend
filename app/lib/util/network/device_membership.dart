import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_isolates/model/device.dart';

/// Subnet evidence for each dialable peer entry, never an OS route assertion.
class DeviceNetworkMembership {
  final String host;
  final List<LocalNetworkAddress> matches;
  const DeviceNetworkMembership(this.host, this.matches);
  bool get overlapping => matches.map((a) => '${a.interfaceName}:${a.interfaceIndex}').toSet().length > 1;
  bool get unknown => matches.isEmpty;
}

List<DeviceNetworkMembership> deviceNetworkMemberships(Device device, List<LocalNetworkAddress> addresses) {
  final hosts = {for (final channel in device.channels.whereType<HttpChannel>()) channel.host, if (device.ip != null) device.ip!};
  return [for (final host in hosts) DeviceNetworkMembership(host, List.unmodifiable(addresses.where((address) => address.containsHost(host))))];
}
