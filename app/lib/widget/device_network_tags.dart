import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/util/network/device_membership.dart';
import 'package:localsend_app/widget/network_address_tags.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shows subnet evidence, not an unverified claim about the selected OS route.
class DeviceNetworkTags extends StatelessWidget {
  final Device device;
  const DeviceNetworkTags({required this.device});

  @override
  Widget build(BuildContext context) {
    final addresses = context.watch(localIpProvider).addresses;
    final memberships = deviceNetworkMemberships(device, addresses);
    final labels = <String, Widget>{};
    for (final membership in memberships) {
      final host = membership.host;
      final matches = membership.matches;
      if (matches.isEmpty) {
        labels[host] = StatusTag(label: '$host · ${t.networkLabels.routedOrUnknown}');
      } else {
        for (final address in matches) {
          labels['${address.interfaceName}:${address.interfaceIndex}:${address.cidr}'] = NetworkAddressTags(address: address);
        }
      }
    }
    if (memberships.any((membership) => membership.overlapping)) {
      labels['overlapping'] = StatusTag(label: t.networkLabels.overlappingNetworks);
    }
    if (labels.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: t.networkLabels.networkMatch,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: labels.values.toList(),
      ),
    );
  }
}
