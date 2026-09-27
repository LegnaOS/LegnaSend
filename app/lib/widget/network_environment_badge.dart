import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:refena_flutter/refena_flutter.dart';

final networkEnvironmentProvider = ViewProvider((ref) => ref.watch(localIpProvider));

String networkAddressKind(LocalNetworkAddress address) => address.isTunnel ? t.networkEnvironment.tunnel : t.networkEnvironment.local;
String networkEnvironmentLabel(NetworkState network) => [
  if (network.vpnDetected) t.networkEnvironment.vpn,
  if (!network.vpnDetected && network.tunnelInterfaces.isNotEmpty) t.networkEnvironment.tunnel,
  if (network.proxyEnabled) t.networkEnvironment.proxy,
].join(' · ');

class NetworkEnvironmentBadge extends StatelessWidget {
  final NetworkState network;
  final GlobalKey<NavigatorState>? navigatorKey;
  const NetworkEnvironmentBadge({required this.network, this.navigatorKey});

  @override
  Widget build(BuildContext context) {
    return StatusTag(
      key: const ValueKey('network-environment-badge'),
      icon: Icons.shield_outlined,
      label: networkEnvironmentLabel(network),
      onTap: () => showDialog<void>(context: navigatorKey?.currentState?.overlay?.context ?? context, builder: (_) => const _NetworkDetails()),
    );
  }
}

class _NetworkDetails extends StatelessWidget {
  const _NetworkDetails();

  @override
  Widget build(BuildContext context) {
    final network = context.watch(networkEnvironmentProvider);
    String signal(bool known, bool active) => !known
        ? t.networkEnvironment.unknown
        : active
        ? t.networkEnvironment.detected
        : t.networkEnvironment.notDetected;
    return AlertDialog(
      title: Text(t.networkEnvironment.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${t.networkEnvironment.vpn}: ${signal(network.vpnKnown, network.vpnDetected)}'),
              Text('${t.networkEnvironment.proxy}: ${signal(network.proxyKnown, network.proxyEnabled)}'),
              if (network.tunnelInterfaces.isNotEmpty) Text('${t.networkEnvironment.tunnel}: ${network.tunnelInterfaces.join(', ')}'),
              const SizedBox(height: 12),
              Text(t.networkEnvironment.routeHint),
              const Divider(),
              for (final address in network.addresses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(
                    '${networkAddressKind(address)} · ${address.label}\n${address.address} · ${address.cidr ?? t.networkLabels.unknownSubnet}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.ref.redux(localIpProvider).dispatchAsync(FetchLocalIpAction()), child: Text(t.networkLabels.refresh)),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close)),
      ],
    );
  }
}
