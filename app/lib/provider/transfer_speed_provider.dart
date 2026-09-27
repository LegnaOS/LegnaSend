import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_isolates/util/rolling_transfer_rate.dart';
import 'package:refena_flutter/refena_flutter.dart';

final transferSpeedProvider = NotifierProvider<TransferSpeedNotifier, Map<String, int?>>((ref) => TransferSpeedNotifier());

/// One sampler shared by progress pages, direction badges and task panels.
/// Only actively transferring sessions start the timer; completed history never
/// contributes to directional rates, and send/receive identities stay separate.
class TransferSpeedNotifier extends Notifier<Map<String, int?>> {
  final int Function()? clock;
  final _watch = Stopwatch()..start();
  final _meters = <String, RollingTransferRate>{};
  final _pendingRebase = <String>{};
  Map<String, TransferActivity> _active = {};
  StreamSubscription? _subscription;
  Timer? _timer;

  TransferSpeedNotifier({this.clock});
  int get _now => clock?.call() ?? _watch.elapsedMilliseconds;

  @override
  Map<String, int?> init() {
    final initial = _sync(ref.read(transferActivityProvider), const {});
    _subscription = ref.stream(transferActivityProvider).listen((event) {
      final next = _sync(event.next, state);
      if (!mapEquals(next, state)) state = next;
    });
    return initial;
  }

  Map<String, int?> _sync(List<TransferActivity> tasks, Map<String, int?> previous) {
    _active = {
      for (final task in tasks)
        if (task.phase == TransferPhase.transferring) task.key: task,
    };
    _meters.removeWhere((key, _) => !_active.containsKey(key));
    _pendingRebase.removeWhere((key) => !_active.containsKey(key));
    final next = <String, int?>{};
    final now = _now;
    for (final entry in _active.entries) {
      if (!_meters.containsKey(entry.key)) {
        _meters[entry.key] = RollingTransferRate()..sample(bytes: entry.value.transferredBytes, nowMs: now);
        next[entry.key] = null;
      } else {
        next[entry.key] = previous[entry.key];
      }
    }
    if (_active.isEmpty) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) => _sample());
    }
    return next;
  }

  /// Reset the sampling baseline after a verified remote checkpoint. Already
  /// stored bytes are progress, not bytes transported in this time window.
  void rebase(String key) {
    _pendingRebase.add(key);
    state = {...state, key: null};
  }

  // Sum per-file bytes only on the shared tick, not on every progress event.
  void _sample() {
    final now = _now;
    final next = <String, int?>{};
    for (final entry in _active.entries) {
      if (_pendingRebase.remove(entry.key)) {
        _meters[entry.key] = RollingTransferRate()..sample(bytes: entry.value.transferredBytes, nowMs: now);
        next[entry.key] = null;
      } else {
        next[entry.key] = _meters[entry.key]!.sample(bytes: entry.value.transferredBytes, nowMs: now);
      }
    }
    if (!mapEquals(next, state)) state = next;
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _watch.stop();
    super.dispose();
  }
}

int? directionalTransferSpeed(Map<String, int?> rates, Iterable<TransferActivity> tasks, TransferDirection direction) {
  final active = tasks.where((task) => task.direction == direction && task.phase == TransferPhase.transferring).toList();
  if (active.isEmpty || active.any((task) => rates[task.key] == null)) return null;
  return active.fold<int>(0, (sum, task) => sum + rates[task.key]!);
}
