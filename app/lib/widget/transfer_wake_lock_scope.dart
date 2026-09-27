import 'package:flutter/material.dart';
import 'package:localsend_app/util/ui/transfer_wake_lock.dart';

/// A foreground task lease, independent of any progress route or bottom sheet.
/// This prevents automatic screen sleep during an iOS transfer after its details
/// are dismissed. It is not an iOS background-execution entitlement.
class TransferWakeLockScope extends StatefulWidget {
  final bool active;
  final TransferWakeLock manager;
  final Widget child;
  const TransferWakeLockScope({required this.active, required this.manager, required this.child, super.key});

  @override
  State<TransferWakeLockScope> createState() => _TransferWakeLockScopeState();
}

class _TransferWakeLockScopeState extends State<TransferWakeLockScope> with WidgetsBindingObserver {
  TransferWakeLockLease? _lease;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
    _sync();
  }

  bool _isForeground(AppLifecycleState? state) => state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  void _sync() {
    if (widget.active && _foreground) {
      _lease ??= widget.manager.acquire();
    } else {
      _lease?.release();
      _lease = null;
    }
  }

  @override
  void didUpdateWidget(covariant TransferWakeLockScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.manager, oldWidget.manager)) {
      _lease?.release();
      _lease = null;
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    _sync();
    // The platform may drop idle-timer state during suspension. Serialize a
    // fresh application behind any old pending toggle, even if demand is equal.
    if (state == AppLifecycleState.resumed && _lease != null) widget.manager.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
