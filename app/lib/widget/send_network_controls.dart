import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/channel_health_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/util/channel_health_strings.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:refena_flutter/refena_flutter.dart';

class SendNetworkFilter extends StatelessWidget {
  const SendNetworkFilter({super.key});
  @override
  Widget build(BuildContext context) {
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final selected = context.watch(sendNetworkFilterProvider);
    final addresses = context.watch(localIpProvider).addresses;
    final options = <String, String>{
      'all': labels.all,
      'local': labels.local,
      'tunnel': labels.tunnel,
      'routed': labels.routed,
      for (final address in addresses.where((a) => a.cidr != null)) networkFilterKey(address): '${address.label} · ${address.cidr}',
    };
    if (!options.containsKey(selected)) options[selected] = labels.missingNetwork;
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final entry in options.entries)
          StatusTag(
            key: ValueKey('network-filter-${entry.key}'),
            label: entry.value,
            icon: entry.key == selected ? Icons.check : null,
            backgroundColor: entry.key == selected ? colors.primaryContainer : null,
            foregroundColor: entry.key == selected ? colors.onPrimaryContainer : null,
            tooltip: labels.hint,
            onTap: () => context.ref.notifier(sendNetworkFilterProvider).select(entry.key),
          ),
      ],
    );
  }
}

class SendChannelSelector extends StatelessWidget {
  final Device device;
  const SendChannelSelector({super.key, required this.device});
  @override
  Widget build(BuildContext context) {
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final selected = context.watch(sendRouteProvider)[sendDeviceKey(device)];
    final available = deviceHttpChannels(device);
    if (available.isEmpty && selected == null) return const SizedBox.shrink();
    final unavailable = selected != null && !available.contains(selected);
    return StatusTag(
      key: ValueKey('send-channel-${sendDeviceKey(device)}'),
      label: selected == null ? labels.automatic : '${labels.choose} · ${httpChannelLabel(selected)}',
      icon: unavailable ? Icons.warning_amber_rounded : Icons.route,
      tooltip: unavailable ? labels.unavailable : labels.hint,
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (_) => _ChannelDialog(device: device),
        );
      },
    );
  }
}

class _ChannelDialog extends StatelessWidget {
  final Device device;
  const _ChannelDialog({required this.device});
  @override
  Widget build(BuildContext context) {
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final selected = context.watch(sendRouteProvider)[sendDeviceKey(device)];
    final current = context.watch(nearbyChannelDevicesProvider)[device.fingerprint] ?? device;
    final channels = deviceHttpChannels(current);
    final health = context.watch(channelHealthProvider);
    final healthLabels = ChannelHealthStrings(Translations.of(context).$meta.locale);
    final localRoute = context.watch(sendLocalRouteProvider)[sendDeviceKey(current)];
    final addresses = context.watch(localIpProvider).addresses;
    void choose(HttpChannel? channel) {
      context.ref.notifier(sendRouteProvider).select(device, channel);
      Navigator.of(context).pop();
    }

    return AlertDialog(
      title: Text(labels.choose),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(labels.hint),
              const SizedBox(height: 8),
              Tooltip(message: healthLabels.hint, child: const Icon(Icons.info_outline, size: 20)),
              const SizedBox(height: 12),
              ListTile(
                key: const ValueKey('send-channel-auto'),
                selected: selected == null,
                leading: Icon(selected == null ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(labels.automatic),
                onTap: () => choose(null),
              ),
              if (selected != null && !channels.contains(selected)) Text(labels.unavailable),
              for (final channel in channels)
                ListTile(
                  key: ValueKey('send-channel-option-${httpChannelLabel(channel)}'),
                  selected: selected == channel,
                  leading: Icon(selected == channel ? Icons.radio_button_checked : Icons.radio_button_off),
                  title: Text(httpChannelLabel(channel)),
                  subtitle: Text(
                    [
                      for (final address in addresses.where((a) => a.containsHost(channel.host)))
                        '${address.isTunnel ? labels.tunnel : labels.local} · ${address.label} · ${address.cidr}',
                      if (!addresses.any((a) => a.containsHost(channel.host))) labels.routed,
                      switch (health[(sendDeviceKey(current), channel)]?.phase) {
                        ChannelHealthPhase.checking => healthLabels.checking,
                        ChannelHealthPhase.reachable => healthLabels.reachable,
                        ChannelHealthPhase.unreachable => healthLabels.unreachable,
                        null => healthLabels.unknown,
                      },
                    ].join('\n'),
                  ),
                  trailing: IconButton(
                    key: ValueKey('probe-${httpChannelLabel(channel)}'),
                    tooltip: healthLabels.check,
                    onPressed: health[(sendDeviceKey(current), channel)]?.phase == ChannelHealthPhase.checking
                        ? null
                        : () => context.ref.notifier(channelHealthProvider).check(current, channel, route: localRoute),
                    icon: const Icon(Icons.network_check),
                  ),
                  onTap: () => choose(channel),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close))],
    );
  }
}

/// Separate from receiver-address selection: this constrains the local sockets
/// of newly queued jobs and never mutates an already running send.
class SendLocalRouteSelector extends StatelessWidget {
  final Device device;
  const SendLocalRouteSelector({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    if (deviceHttpChannels(device).isEmpty) return const SizedBox.shrink();
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final route = context.watch(sendLocalRouteProvider)[sendDeviceKey(device)];
    final addresses = context.watch(localIpProvider).addresses;
    final host = context.watch(sendRouteProvider)[sendDeviceKey(device)]?.host ?? device.ip;
    final unavailable = route != null && (!localSendRouteAvailable(route, addresses) || !localSendRouteMatchesHost(route, host));
    final colors = Theme.of(context).colorScheme;
    return StatusTag(
      key: ValueKey('send-local-route-${sendDeviceKey(device)}'),
      label: '${labels.localExit} · ${route == null ? labels.automaticExit : localSendRouteLabel(route)}',
      icon: unavailable ? Icons.warning_amber_rounded : Icons.settings_ethernet,
      backgroundColor: unavailable ? colors.errorContainer : null,
      foregroundColor: unavailable ? colors.onErrorContainer : null,
      tooltip: unavailable ? labels.localRouteUnavailable : labels.routeDetails,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _LocalRouteDialog(device: device),
      ),
    );
  }
}

class _LocalRouteDialog extends StatelessWidget {
  final Device device;
  const _LocalRouteDialog({required this.device});

  @override
  Widget build(BuildContext context) {
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final selected = context.watch(sendLocalRouteProvider)[sendDeviceKey(device)];
    final all = context.watch(localIpProvider).addresses;
    final addresses =
        <String, LocalNetworkAddress>{
          for (final address in all.where((address) => address.hasNonLinkLocalAddress))
            '${address.interfaceName}/${address.address}/${address.androidNetworkHandle}/${address.androidNetworkEpoch}': address,
        }.values.toList()..sort(
          (a, b) => a.isTunnel == b.isTunnel
              ? '${a.interfaceName}/${a.address}'.compareTo('${b.interfaceName}/${b.address}')
              : a.isTunnel
              ? 1
              : -1,
        );
    final host = context.watch(sendRouteProvider)[sendDeviceKey(device)]?.host ?? device.ip;
    final boundInterface = const {
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);
    void choose(LocalSendRoute? route) {
      context.ref.notifier(sendLocalRouteProvider).select(device, route);
      Navigator.of(context).pop();
    }

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(labels.localExit)),
          IconButton(
            key: const ValueKey('send-local-route-info'),
            tooltip: labels.routeDetails,
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(labels.routeDetails),
                content: SingleChildScrollView(child: Text(labels.bindingHint)),
                actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close))],
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * .52,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusTag(
              label: boundInterface
                  ? labels.interfaceBinding
                  : all.any((a) => a.androidNetworkHandle != null)
                  ? labels.androidNetworkBinding
                  : labels.sourceBinding,
            ),
            const SizedBox(height: 8),
            if (selected != null && !localSendRouteAvailable(selected, all))
              Text(labels.localRouteUnavailable, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Expanded(
              child: ListView.builder(
                itemCount: addresses.length + 1 + (addresses.isEmpty ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      key: const ValueKey('send-local-route-auto'),
                      selected: selected == null,
                      leading: Icon(selected == null ? Icons.radio_button_checked : Icons.radio_button_off),
                      title: Text(labels.automaticExit),
                      onTap: () => choose(null),
                    );
                  }
                  if (addresses.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text(labels.noLocalAddresses));
                  final address = addresses[index - 1];
                  final route = LocalSendRoute(
                    interfaceName: address.interfaceName,
                    localAddress: address.address.split('%').first,
                    androidNetworkHandle: address.androidNetworkHandle,
                    androidNetworkEpoch: address.androidNetworkEpoch,
                  );
                  final matches = localSendRouteMatchesHost(route, host);
                  return ListTile(
                    key: ValueKey(
                      'send-local-route-option-${address.interfaceName}-${address.address}${address.androidNetworkHandle == null ? '' : '-${address.androidNetworkHandle}'}',
                    ),
                    selected: route == selected,
                    enabled: matches,
                    leading: Icon(route == selected ? Icons.radio_button_checked : Icons.radio_button_off),
                    title: Text(address.address),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            StatusTag(label: address.isTunnel ? labels.tunnelInterface : labels.localInterface),
                            StatusTag(label: address.label),
                            if (defaultTargetPlatform == TargetPlatform.android && all.any((a) => a.androidNetworkHandle != null))
                              StatusTag(label: route.androidNetworkHandle != null ? labels.androidNetworkBinding : labels.sourceBinding),
                            if (address.cidr != null) StatusTag(label: address.cidr!),
                          ],
                        ),
                        if (!matches) Text(labels.addressFamilyMismatch),
                      ],
                    ),
                    onTap: matches ? () => choose(route) : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close))],
    );
  }
}
