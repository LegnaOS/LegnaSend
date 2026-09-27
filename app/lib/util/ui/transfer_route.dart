import 'dart:async';

import 'package:flutter/material.dart';

/// Owns exactly one task route, without popping unrelated requests or pages.
class TransferRoute {
  final NavigatorState navigator;
  Route<void>? _route;

  TransferRoute(BuildContext context) : navigator = Navigator.of(context);

  bool get isOpen => _route?.isActive == true;
  bool get isCurrent => _route?.isCurrent == true;

  Future<void> show(WidgetBuilder builder) {
    final next = MaterialPageRoute<void>(builder: builder);
    final previous = _route;
    _route = next;
    if (previous?.isActive == true) {
      if (previous!.isCurrent) {
        unawaited(navigator.pushReplacement(next));
      } else {
        // Replace only our covered route; do not cover a newer receive prompt.
        navigator.replace(oldRoute: previous, newRoute: next);
      }
    } else {
      unawaited(navigator.push(next));
    }
    return next.popped;
  }

  void close() {
    final route = _route;
    _route = null;
    if (navigator.mounted && route?.isActive == true) navigator.removeRoute(route!);
  }
}

/// Removes this page only, even if a newer request is currently above it.
void closeTransferPage(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
}
