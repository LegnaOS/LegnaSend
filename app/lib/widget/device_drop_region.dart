import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

final deviceDropHoverProvider = NotifierProvider<DeviceDropHover, Device?>((ref) => DeviceDropHover());

class DeviceDropHover extends Notifier<Device?> {
  @override
  Device? init() => null;
  void set(Device? device) => state = device;
}

class DeviceDropDestination {
  final Device device;
  const DeviceDropDestination(this.device);
}

/// A hit-test marker, not a second native DropTarget. The home page alone
/// consumes OS drop events, so a card and its parent cannot send twice.
class DeviceDropRegion extends StatelessWidget {
  final Device device;
  final Widget child;
  const DeviceDropRegion({required this.device, required this.child});

  @override
  Widget build(BuildContext context) {
    final hover = context.watch(deviceDropHoverProvider);
    final highlighted = hover != null && hover.fingerprint == device.fingerprint && hover.ip == device.ip;
    return MetaData(
      metaData: DeviceDropDestination(device),
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(width: 2, color: highlighted ? Theme.of(context).colorScheme.primary : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }
}

Device? hitTestDropDevice(BuildContext context, Offset position) {
  final result = BoxHitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderMetaData && target.metaData is DeviceDropDestination) {
      return (target.metaData as DeviceDropDestination).device;
    }
  }
  return null;
}
