import 'dart:async';

import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as wire;
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum ChannelHealthPhase { checking, reachable, unreachable }

class ChannelHealth {
  final ChannelHealthPhase phase;
  final DateTime checkedAt;
  final LocalSendRoute? route;
  const ChannelHealth(this.phase, this.checkedAt, this.route);
}

typedef ChannelHealthKey = (String, HttpChannel);
typedef ChannelProbe = Future<bool> Function(Device device, HttpChannel channel, LocalSendRoute? route);

final channelProbeProvider = Provider<ChannelProbe>(
  (ref) => (device, channel, route) async {
    if (device.fingerprint.isEmpty) return false;
    final security = ref.read(securityProvider);
    final client = createClient(
      privateKey: security.privateKey,
      cert: security.certificate,
      version: LsHttpClientVersion.v2,
      expectedFingerprint: device.fingerprint,
      timeoutMs: 4000,
      localAddress: route?.localAddress,
      interfaceName: route?.interfaceName,
      androidNetworkHandle: route?.androidNetworkHandle,
      androidNetworkEpoch: route?.androidNetworkEpoch,
    );
    final result = await client.register(
      protocol: channel.https ? wire.ProtocolType.https : wire.ProtocolType.http,
      ip: channel.host,
      port: channel.port,
      payload: ref.read(deviceFullInfoProvider).toRegisterDto(),
    );
    // HTTPS is pinned before HTTP. HTTP only offers claimed identity, not TLS authentication.
    return result.body.token == device.fingerprint;
  },
);

final channelHealthProvider = NotifierProvider<ChannelHealthNotifier, Map<ChannelHealthKey, ChannelHealth>>((ref) {
  final notifier = ChannelHealthNotifier(ref.read(channelProbeProvider));
  notifier.subscriptions.add(
    ref.stream(localIpProvider).listen((event) {
      if (event.prev != event.next) notifier.invalidate();
    }),
  );
  notifier.subscriptions.add(ref.stream(sendLocalRouteProvider).listen((_) => notifier.invalidate()));
  notifier.subscriptions.add(ref.stream(nearbyChannelDevicesProvider).listen((event) => notifier.reconcile(event.prev, event.next)));
  return notifier;
});

class ChannelHealthNotifier extends Notifier<Map<ChannelHealthKey, ChannelHealth>> {
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ChannelProbe probe;
  final Duration lifetime;
  final _versions = <ChannelHealthKey, Object>{};
  final _expiry = <ChannelHealthKey, Timer>{};
  int _active = 0;
  bool _disposed = false;
  ChannelHealthNotifier(this.probe, {this.lifetime = const Duration(seconds: 60)});
  @override
  Map<ChannelHealthKey, ChannelHealth> init() => {};
  void invalidate() {
    if (_disposed) return;
    _versions.clear();
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    state = {};
  }

  void reconcile(Map<String, Device> previous, Map<String, Device> current) {
    if (_disposed) return;
    final removed = state.keys
        .where((key) => previous.containsKey(key.$1) && (!current.containsKey(key.$1) || !deviceHttpChannels(current[key.$1]!).contains(key.$2)))
        .toList();
    if (removed.isEmpty) return;
    final next = {...state};
    for (final key in removed) {
      _versions.remove(key);
      _expiry.remove(key)?.cancel();
      next.remove(key);
    }
    state = next;
  }

  Future<void> check(Device device, HttpChannel channel, {LocalSendRoute? route}) async {
    final key = (sendDeviceKey(device), channel);
    if (_disposed || _active >= 4 || state[key]?.phase == ChannelHealthPhase.checking || !deviceHttpChannels(device).contains(channel)) return;
    if (state.length >= 256 && !state.containsKey(key)) {
      final oldest = state.keys.firstWhere((key) => state[key]!.phase != ChannelHealthPhase.checking);
      _expiry.remove(oldest)?.cancel();
      _versions.remove(oldest);
      state = {...state}..remove(oldest);
    }
    final version = Object();
    _versions[key] = version;
    _expiry.remove(key)?.cancel();
    _active++;
    state = {...state, key: ChannelHealth(ChannelHealthPhase.checking, DateTime.now(), route)};
    bool reachable;
    try {
      reachable = await probe(device, channel, route);
    } catch (_) {
      reachable = false;
    }
    _active--;
    if (_disposed || !identical(_versions[key], version)) return;
    state = {...state, key: ChannelHealth(reachable ? ChannelHealthPhase.reachable : ChannelHealthPhase.unreachable, DateTime.now(), route)};
    _expiry[key] = Timer(lifetime, () {
      if (_disposed || !identical(_versions[key], version)) return;
      _versions.remove(key);
      _expiry.remove(key);
      state = {...state}..remove(key);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _versions.clear();
    super.dispose();
  }
}
