import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/util/native/android_network_routes.dart';

class NetworkSignals {
  final List<LocalNetworkAddress>? androidNetworks;
  final bool vpnDetected;
  final bool vpnKnown;
  final bool proxyEnabled;
  final bool proxyKnown;
  const NetworkSignals({this.vpnDetected = false, this.vpnKnown = false, this.proxyEnabled = false, this.proxyKnown = false, this.androidNetworks});
}

/// Read-only OS hints. Neither an HTTP proxy setting nor a tunnel interface proves
/// the route of an individual connection. Never read or expose proxy credentials.
Future<NetworkSignals> readNetworkSignals() async {
  List<ConnectivityResult>? connectivity;
  try {
    connectivity = await Connectivity().checkConnectivity().timeout(const Duration(seconds: 1));
  } catch (_) {}
  final supportedVpn = Platform.isAndroid || Platform.isLinux || Platform.isWindows;
  Map<String, dynamic>? native;
  final channel = Platform.isMacOS
      ? 'main-delegate-channel'
      : Platform.isIOS
      ? 'ios-delegate-channel'
      : Platform.isAndroid
      ? 'org.localsend.localsend_app/localsend'
      : null;
  if (channel != null) {
    try {
      native = await MethodChannel(channel).invokeMapMethod<String, dynamic>('networkSignals').timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
  return NetworkSignals(
    androidNetworks: Platform.isAndroid ? applyAndroidNetworkSnapshot(native?['networkRoutes']) : null,
    vpnDetected: native?['vpnDetected'] == true || connectivity?.contains(ConnectivityResult.vpn) == true,
    vpnKnown: native?['vpnKnown'] == true || supportedVpn && connectivity != null,
    proxyEnabled: native?['proxyEnabled'] == true,
    proxyKnown: native?['proxyKnown'] == true,
  );
}
