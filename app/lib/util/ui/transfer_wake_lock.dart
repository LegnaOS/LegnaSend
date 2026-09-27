import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _log = Logger('TransferWakeLock');
final transferWakeLockProvider = Provider(
  (ref) => TransferWakeLock(
    toggle: (enabled) => WakelockPlus.toggle(enable: enabled),
    onError: (error, stack) => _log.warning('Transfer wake-lock update failed', error, stack),
  ),
);

/// Transfer tasks and visible active progress pages each own a lease. Native toggles are
/// serialized: an old pending disable cannot finish after a newer enable.
class TransferWakeLock {
  final Future<void> Function(bool enabled) toggle;
  final void Function(Object error, StackTrace stack)? onError;
  int _owners = 0;
  bool? _applied = false;
  Future<void> _tail = Future<void>.value();
  TransferWakeLock({required this.toggle, this.onError});

  Future<void> get settled => _tail;

  TransferWakeLockLease acquire() {
    _owners++;
    _update();
    return TransferWakeLockLease._(() {
      _owners--;
      _update();
    });
  }

  /// Reapply current demand after a platform lifecycle transition.
  void refresh() => _update(force: true);

  void _update({bool force = false}) {
    _tail = _tail.then((_) async {
      // Read current demand when this operation begins, not when it was queued.
      // This coalesces release/reacquire while another platform call is pending.
      final enabled = _owners > 0;
      if (!force && _applied == enabled) return;
      try {
        await toggle(enabled);
        _applied = enabled;
      } catch (error, stack) {
        // A failed platform call may have partially applied. The next demand
        // transition must reconcile instead of assuming the previous state.
        _applied = null;
        try {
          onError?.call(error, stack);
        } catch (_) {
          // Diagnostic failures must not poison later resource operations.
        }
      }
    });
  }
}

class TransferWakeLockLease {
  final void Function() _release;
  bool _released = false;
  TransferWakeLockLease._(this._release);
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}
