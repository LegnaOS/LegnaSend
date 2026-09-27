import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Session-only preferences: queued jobs snapshot the choice instead of reading
/// this mutable UI state again when they start or retry.
final sendRouteProvider = NotifierProvider<SendRouteNotifier, Map<String, HttpChannel>>((ref) => SendRouteNotifier());

class SendRouteNotifier extends Notifier<Map<String, HttpChannel>> {
  @override
  Map<String, HttpChannel> init() => {};

  void select(Device device, HttpChannel? channel) {
    final next = Map<String, HttpChannel>.of(state);
    if (channel == null) {
      next.remove(sendDeviceKey(device));
    } else {
      next[sendDeviceKey(device)] = channel;
    }
    state = Map.unmodifiable(next);
  }
}

final sendNetworkFilterProvider = NotifierProvider<SendNetworkFilterNotifier, String>((ref) => SendNetworkFilterNotifier());

class SendNetworkFilterNotifier extends Notifier<String> {
  @override
  String init() => 'all';
  void select(String filter) => state = filter;
}

/// Local socket constraints are separate from receiver entry points. New jobs
/// snapshot this value; changing the selector never reroutes an existing job.
final sendLocalRouteProvider = NotifierProvider<SendLocalRouteNotifier, Map<String, LocalSendRoute>>((ref) => SendLocalRouteNotifier());

class SendLocalRouteNotifier extends Notifier<Map<String, LocalSendRoute>> {
  @override
  Map<String, LocalSendRoute> init() => {};

  void select(Device device, LocalSendRoute? route) {
    final next = Map<String, LocalSendRoute>.of(state);
    if (route == null) {
      next.remove(sendDeviceKey(device));
    } else {
      next[sendDeviceKey(device)] = route;
    }
    state = Map.unmodifiable(next);
  }
}
