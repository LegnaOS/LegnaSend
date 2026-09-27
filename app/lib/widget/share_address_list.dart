import 'package:flutter/material.dart';
import 'package:localsend_app/model/local_network_address.dart';

/// Prefer ordinary IPv4; keep alternate routes available without a tall card.
class ShareAddressList extends StatelessWidget {
  final List<LocalNetworkAddress> addresses;
  final Widget Function(LocalNetworkAddress) itemBuilder;
  final String moreLabel;
  const ShareAddressList({super.key, required this.addresses, required this.itemBuilder, required this.moreLabel});

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final sorted = addresses.where((a) => a.hasNonLinkLocalAddress && seen.add(a.address)).toList()
      ..sort((a, b) {
        final priorityA = (a.isIpv6 ? 2 : 0) + (a.isTunnel ? 1 : 0);
        final priorityB = (b.isIpv6 ? 2 : 0) + (b.isTunnel ? 1 : 0);
        final order = priorityA.compareTo(priorityB);
        return order != 0 ? order : a.address.compareTo(b.address);
      });
    if (sorted.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        itemBuilder(sorted.first),
        if (sorted.length > 1)
          ExpansionTile(
            key: const ValueKey('share-more-addresses'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('$moreLabel (${sorted.length - 1})', style: Theme.of(context).textTheme.bodySmall),
            children: sorted.skip(1).map(itemBuilder).toList(growable: false),
          ),
      ],
    );
  }
}
