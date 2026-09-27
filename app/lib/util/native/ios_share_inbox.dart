import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_handler/share_handler.dart';

/// Serial delivery prevents startup/resume overlap. A failed enqueue leaves the
/// native manifest intact, and successful delivery retains its immutable files.
class IosShareInbox {
  final MethodChannel channel;
  final void Function(String)? onAcknowledged;
  final void Function()? onDrained;
  Future<bool>? _draining;
  final Set<String> _delivered = {};
  IosShareInbox({this.channel = const MethodChannel('legnasend/ios_share'), this.onAcknowledged, this.onDrained});

  Future<bool> drain(Future<void> Function(String, SharedMedia) enqueue) {
    return _draining ??= _drain(enqueue).whenComplete(() => _draining = null);
  }

  Future<bool> _drain(Future<void> Function(String, SharedMedia) enqueue) async {
    var imported = false;
    while (true) {
      final value = await channel.invokeMapMethod<String, Object?>('next');
      if (value == null) {
        onDrained?.call();
        _delivered.clear();
        return imported;
      }
      final id = value['batchId'];
      if (id is! String || !RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$').hasMatch(id)) {
        throw const FormatException('Invalid iOS share batch');
      }
      if (!_delivered.contains(id)) {
        await enqueue(id, SharedMedia.decode(value));
        _delivered.add(id);
      }
      // If acknowledgement fails, a retry acknowledges without re-enqueueing.
      await channel.invokeMethod<void>('acknowledge', {'batchId': id});
      onAcknowledged?.call(id);
      _delivered.remove(id);
      imported = true;
    }
  }
}
