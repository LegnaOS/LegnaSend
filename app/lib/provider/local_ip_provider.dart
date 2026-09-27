import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/android_network_routes.dart';
import 'package:localsend_app/util/native/network_signals.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/util/network_interfaces.dart';
import 'package:localsend_isolates/util/network_snapshot.dart';
import 'package:logging/logging.dart';
import 'package:network_info_plus/network_info_plus.dart' as plugin;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('NetworkInfo');

final localIpProvider = ReduxProvider<LocalIpService, NetworkState>((ref) {
  return LocalIpService(
    ref.notifier(settingsProvider),
    onNetworkChanged: () => ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction()),
  );
});

class LocalIpService extends ReduxNotifier<NetworkState> {
  final SettingsService _settingsService;
  final void Function()? onNetworkChanged;
  StreamSubscription? _subscription;
  StreamSubscription? _androidRoutesSubscription;
  Timer? _refreshTimer;
  int _generation = 0;
  Future<NetworkState>? _pendingSnapshot;
  List<String>? _pendingWhitelist;
  List<String>? _pendingBlacklist;
  final Future<NetworkState> Function(List<String>?, List<String>?)? snapshotLoader;
  final bool monitor;

  Future<NetworkState> snapshot(List<String>? whitelist, List<String>? blacklist) async {
    final running = _pendingSnapshot;
    if (running != null && listEquals(whitelist, _pendingWhitelist) && listEquals(blacklist, _pendingBlacklist)) return running;
    _pendingWhitelist = whitelist == null ? null : List.of(whitelist);
    _pendingBlacklist = blacklist == null ? null : List.of(blacklist);
    final future = _pendingSnapshot = (snapshotLoader ?? readNetworkState)(whitelist, blacklist);
    try {
      return await future;
    } finally {
      if (identical(future, _pendingSnapshot)) _pendingSnapshot = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _refreshTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_androidRoutesSubscription?.cancel());
    super.dispose();
  }

  LocalIpService(this._settingsService, {this.onNetworkChanged, this.snapshotLoader, this.monitor = true});

  @override
  NetworkState init() {
    return const NetworkState(
      localIps: [],
      initialized: false,
    );
  }

  @override
  get initialAction => InitLocalIpAction();
}

/// Fetches the local IP address and registers a listener to update the IP address
class InitLocalIpAction extends ReduxAction<LocalIpService, NetworkState> {
  @override
  NetworkState reduce() {
    if (!kIsWeb && notifier.monitor) {
      // ignore: discarded_futures
      notifier._subscription?.cancel();

      if (checkPlatform([TargetPlatform.windows])) {
        // https://github.com/localsend/localsend/issues/12
        // https://github.com/localsend/localsend/issues/78
      } else {
        notifier._subscription = Connectivity().onConnectivityChanged.listen((_) async {
          await dispatchAsync(FetchLocalIpAction());
        });
      }
    }

    // Connectivity events may miss DHCP renewals and a second adapter of the
    // same type. Polling also covers Windows, where the listener is disabled.
    notifier._refreshTimer?.cancel();
    if (!kIsWeb && notifier.monitor) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        notifier._androidRoutesSubscription = const EventChannel('org.localsend.localsend_app/localsend/network-routes')
            .receiveBroadcastStream()
            .listen(
              (snapshot) {
                applyAndroidNetworkSnapshot(snapshot);
                unawaited(dispatchAsync(FetchLocalIpAction()));
              },
              onError: (Object error) {
                applyAndroidNetworkSnapshot(null);
                unawaited(dispatchAsync(FetchLocalIpAction()));
              },
            );
      }
      notifier._refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(dispatchAsync(FetchLocalIpAction()));
      });
    }
    return state;
  }

  @override
  void after() {
    // ignore: discarded_futures
    if (notifier.monitor) dispatchAsync(FetchLocalIpAction());
  }
}

class FetchLocalIpAction extends AsyncReduxAction<LocalIpService, NetworkState> {
  @override
  Future<NetworkState> reduce() async {
    final generation = ++notifier._generation;
    final settings = notifier._settingsService.state;
    final snapshot = await notifier.snapshot(settings.networkWhitelist, settings.networkBlacklist);
    if (generation != notifier._generation) return state;
    final changed =
        state.initialized &&
        (!listEquals(state.addresses, snapshot.addresses) ||
            state.vpnDetected != snapshot.vpnDetected ||
            !listEquals(state.tunnelInterfaces, snapshot.tunnelInterfaces));
    if (changed) {
      // Discovery only: preserve HTTP sessions and the sharing service. A discovery
      // failure must not suppress the visible network-state update.
      try {
        notifier.onNetworkChanged?.call();
      } catch (e) {
        _logger.warning('Discovery refresh failed after network change', e);
      }
    }
    return snapshot;
  }
}

Future<NetworkState> readNetworkState(List<String>? whitelist, List<String>? blacklist) async {
  final signalFuture = readNetworkSignals();
  final all = await fetchLocalNetworkAddresses(whitelist: null, blacklist: null);
  final signals = await signalFuture;
  // An event can retire a Network while interface enumeration is pending.
  // Resolve its latest accepted identities now, not the earlier Future's list.
  final current = Platform.isAndroid
      ? NetworkSignals(
          vpnDetected: signals.vpnDetected,
          vpnKnown: signals.vpnKnown,
          proxyEnabled: signals.proxyEnabled,
          proxyKnown: signals.proxyKnown,
          androidNetworks: currentAndroidNetworkRoutes,
        )
      : signals;
  return composeNetworkState(all: all, signals: current, whitelist: whitelist, blacklist: blacklist);
}

NetworkState composeNetworkState({
  required List<LocalNetworkAddress> all,
  required NetworkSignals signals,
  List<String>? whitelist,
  List<String>? blacklist,
}) {
  final enriched = [
    for (final address in all)
      if (signals.androidNetworks?.any(
            (route) =>
                route.interfaceName == address.interfaceName &&
                listEquals(
                  InternetAddress.tryParse(route.address)?.rawAddress,
                  InternetAddress.tryParse(address.address.split('%').first)?.rawAddress,
                ),
          ) !=
          true)
        address
      else
        ...signals.androidNetworks!
            .where(
              (route) =>
                  route.interfaceName == address.interfaceName &&
                  listEquals(
                    InternetAddress.tryParse(route.address)?.rawAddress,
                    InternetAddress.tryParse(address.address.split('%').first)?.rawAddress,
                  ),
            )
            .map(
              (route) => address.copyWith(
                androidNetworkHandle: route.androidNetworkHandle,
                androidNetworkEpoch: route.androidNetworkEpoch,
                androidVpn: route.androidVpn,
                wifi: route.wifi,
                cellular: route.cellular,
              ),
            ),
  ];
  final tunnels = enriched.where((a) => a.isTunnel && a.hasNonLinkLocalAddress).map((a) => a.interfaceName).toSet().toList()..sort();
  final addresses = enriched
      .where(
        (a) => !isNetworkIgnoredRaw(
          networkWhitelist: whitelist,
          networkBlacklist: blacklist,
          interface: all.where((b) => b.interfaceName == a.interfaceName).map((b) => b.address).toList(),
        ),
      )
      .toList();
  return NetworkState(
    localIps: addresses.where((a) => !a.isIpv6).map((a) => a.address).toSet().toList(),
    initialized: true,
    addresses: addresses,
    vpnDetected: signals.vpnDetected,
    vpnKnown: signals.vpnKnown,
    proxyEnabled: signals.proxyEnabled,
    proxyKnown: signals.proxyKnown,
    tunnelInterfaces: tunnels,
  );
}

Future<List<LocalNetworkAddress>> fetchLocalNetworkAddresses({
  required List<String>? whitelist,
  required List<String>? blacklist,
}) async {
  String? wifiIp;
  try {
    wifiIp = await plugin.NetworkInfo().getWifiIP().timeout(const Duration(seconds: 1));
  } catch (e) {
    _logger.fine('Wi-Fi address unavailable', e);
  }
  List<LocalNetworkAddress> addresses;
  try {
    final snapshot = await getNetworkAddresses(whitelist: whitelist, blacklist: blacklist);
    addresses = snapshot
        .map(
          (a) => LocalNetworkAddress(
            interfaceName: a.name,
            interfaceIndex: a.index,
            address: a.address,
            prefixLength: a.prefixLength,
            wifi: a.address == wifiIp,
          ),
        )
        .toList();
  } catch (e) {
    _logger.warning('Native interface metadata unavailable; falling back to interface names', e);
    try {
      final interfaces = await getNetworkInterfaces(whitelist: whitelist, blacklist: blacklist);
      addresses = [
        for (final i in interfaces)
          for (final a in i.addresses)
            LocalNetworkAddress(interfaceName: i.name, interfaceIndex: i.index, address: a.address, wifi: a.address == wifiIp),
      ];
    } catch (e) {
      _logger.warning('Interface enumeration failed', e);
      addresses = [];
    }
  }
  // Never re-add the Wi-Fi plugin address: it may belong to an excluded adapter.
  // Keep all addresses associated with their original interface, even if duplicated.
  addresses.sort((a, b) {
    if (a.isTunnel != b.isTunnel) return a.isTunnel ? 1 : -1;
    if (a.wifi != b.wifi) return a.wifi ? -1 : 1;
    final name = a.interfaceName.compareTo(b.interfaceName);
    return name != 0 ? name : a.address.compareTo(b.address);
  });
  return addresses;
}

List<String> rankIpAddresses(List<String> nativeResult, String? thirdPartyResult) {
  if (thirdPartyResult == null) {
    // only take the list
    return nativeResult._rankIpAddresses(null);
  } else if (nativeResult.isEmpty) {
    // only take the first IP from third party library
    return [thirdPartyResult];
  } else if (thirdPartyResult.endsWith('.1')) {
    // merge
    return {thirdPartyResult, ...nativeResult}.toList()._rankIpAddresses(null);
  } else {
    // merge but prefer result from third party library
    return {thirdPartyResult, ...nativeResult}.toList()._rankIpAddresses(thirdPartyResult);
  }
}

/// Sorts Ip addresses with first being the most likely primary local address
/// Currently,
/// - sorts ending with ".1" last
/// - primary is always first
extension ListIpExt on List<String> {
  List<String> _rankIpAddresses(String? primary) {
    return sorted((a, b) {
      int scoreA = a == primary ? 10 : (a.endsWith('.1') ? 0 : 1);
      int scoreB = b == primary ? 10 : (b.endsWith('.1') ? 0 : 1);
      return scoreB.compareTo(scoreA);
    });
  }
}
