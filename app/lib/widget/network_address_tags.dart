import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/status_tag.dart';

class NetworkAddressTags extends StatelessWidget {
  final LocalNetworkAddress address;
  const NetworkAddressTags({required this.address});
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        StatusTag(label: networkAddressKind(address), icon: address.isTunnel ? Icons.shield_outlined : Icons.lan_outlined),
        if (address.wifi && !address.isTunnel) const StatusTag(label: 'Wi-Fi', icon: Icons.wifi),
        StatusTag(label: address.interfaceName),
        StatusTag(label: address.cidr ?? t.networkLabels.unknownSubnet),
      ],
    ),
  );
}
