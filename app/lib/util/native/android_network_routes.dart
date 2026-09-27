import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_isolates/rust/api/http.dart' as native;

final _androidNetworkSnapshotCache = AndroidNetworkSnapshotCache();
List<LocalNetworkAddress> get currentAndroidNetworkRoutes => _androidNetworkSnapshotCache.current;

/// Only trusted platform snapshots enter this registry; it never binds the process.
List<LocalNetworkAddress> applyAndroidNetworkSnapshot(Object? value, {void Function(String?)? configure, AndroidNetworkSnapshotCache? cache}) =>
    (cache ?? _androidNetworkSnapshotCache).apply(value, configure: configure ?? (value) => native.configureAndroidNetworkRoutes(snapshot: value));

/// Shared by platform events and polled replies. Late replies must not repaint
/// an already retired Network in the UI after native rejected their revision.
class AndroidNetworkSnapshotCache {
  String? _epoch;
  int _revision = 0;
  List<LocalNetworkAddress> _current = const [];
  List<LocalNetworkAddress> get current => _current;
  List<LocalNetworkAddress> apply(Object? value, {required void Function(String?) configure}) {
    final sync = configure;
    try {
      if (value is! Map || value['epoch'] is! String || value['revision'] is! int || value['networks'] is! List) throw const FormatException();
      final uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
      if (!uuid.hasMatch(value['epoch'] as String) || (value['revision'] as int) < 1) throw const FormatException();
      if (_epoch != null && _epoch != value['epoch']) throw const FormatException();
      if (_epoch != null && (value['revision'] as int) <= _revision) return _current;
      final networks = value['networks'] as List;
      if (networks.length > 64) throw const FormatException();
      final result = <LocalNetworkAddress>[];
      for (final item in networks) {
        if (item is! Map || item['interfaceName'] is! String || item['handle'] is! String || item['lease'] is! String || item['addresses'] is! List) {
          throw const FormatException();
        }
        final handle = item['handle'] as String;
        if (!RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(handle) ||
            BigInt.parse(handle) > ((BigInt.one << 64) - BigInt.one) ||
            !uuid.hasMatch(item['lease'] as String) ||
            ['vpn', 'wifi', 'cellular'].any((key) => item[key] is! bool)) {
          throw const FormatException();
        }
        final addresses = item['addresses'] as List;
        if (addresses.length > 64) throw const FormatException();
        for (final address in addresses) {
          if (address is! String || address.contains('%') || InternetAddress.tryParse(address) == null) throw const FormatException();
          result.add(
            LocalNetworkAddress(
              interfaceName: item['interfaceName'] as String,
              address: address,
              androidNetworkHandle: item['handle'] as String,
              androidNetworkEpoch: '${value['epoch']}:${item['lease']}',
              androidVpn: item['vpn'] == true,
              wifi: item['wifi'] == true,
              cellular: item['cellular'] == true,
            ),
          );
        }
      }
      sync(jsonEncode(value));
      _epoch = value['epoch'] as String;
      _revision = value['revision'] as int;
      _current = List.unmodifiable(result);
      return _current;
    } catch (_) {
      try {
        sync(null);
      } catch (_) {}
      _current = const [];
      return _current;
    }
  }
}
