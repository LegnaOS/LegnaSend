import 'package:dart_mappable/dart_mappable.dart';

part 'local_send_route.mapper.dart';

/// Immutable local egress selected for one native send attempt.
///
/// This is a local socket binding, not a remote endpoint or wire-protocol field.
/// A null route preserves automatic OS routing; a selected route must not fall
/// back to an unbound connection when binding fails.
@MappableClass()
class LocalSendRoute with LocalSendRouteMappable {
  final String interfaceName;
  final String localAddress;
  final String? androidNetworkHandle;
  final String? androidNetworkEpoch;

  const LocalSendRoute({
    required this.interfaceName,
    required this.localAddress,
    this.androidNetworkHandle,
    this.androidNetworkEpoch,
  });

  static const fromJson = LocalSendRouteMapper.fromJson;
}
