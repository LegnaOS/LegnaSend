import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_app/model/local_network_address.dart';

part 'network_state.mapper.dart';

@MappableClass()
class NetworkState with NetworkStateMappable {
  final List<String> localIps;
  final bool initialized;
  final List<LocalNetworkAddress> addresses;
  final bool vpnDetected;
  final bool vpnKnown;
  final bool proxyEnabled;
  final bool proxyKnown;
  final List<String> tunnelInterfaces;

  bool get hasNetworkOverlay => vpnDetected || proxyEnabled || tunnelInterfaces.isNotEmpty;

  const NetworkState({
    required this.localIps,
    required this.initialized,
    this.addresses = const [],
    this.vpnDetected = false,
    this.vpnKnown = false,
    this.proxyEnabled = false,
    this.proxyKnown = false,
    this.tunnelInterfaces = const [],
  });
}
