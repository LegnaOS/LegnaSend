import 'dart:async';

import 'package:refena_flutter/refena_flutter.dart';

final sourceCacheLeaseProvider = Provider<SourceCacheCoordinator>((_) => SourceCacheCoordinator());

/// Serializes plugin cache deletion against source acquisition on the host
/// isolate. Long-lived selection/queue/share references are checked separately.
/// This does not lock foreign processes or arbitrary filesystem paths.
class SourceCacheCoordinator {
  int _leases = 0;
  Completer<void>? _cleaning;

  int get activeLeases => _leases;
  bool get cleaning => _cleaning != null;

  Future<SourceCacheLease> acquire() async {
    while (_cleaning != null) {
      await _cleaning!.future;
    }
    _leases++;
    return SourceCacheLease._(() => _leases--);
  }

  Future<T> withLease<T>(Future<T> Function() operation) async {
    final lease = await acquire();
    try {
      return await operation();
    } finally {
      lease.release();
    }
  }

  /// Cleanup is opportunistic, never queued behind sources: a newly published
  /// selection may retain them indefinitely. New acquisitions wait for actual
  /// cleanup completion, including an error, then safely continue.
  Future<bool> cleanIfIdle({required bool Function() inUse, required Future<void> Function() cleanup}) async {
    if (_cleaning != null || _leases != 0 || inUse()) return false;
    final completion = Completer<void>();
    _cleaning = completion;
    try {
      await cleanup();
      return true;
    } finally {
      _cleaning = null;
      completion.complete();
    }
  }
}

class SourceCacheLease {
  void Function()? _release;
  SourceCacheLease._(this._release);

  void release() {
    final release = _release;
    _release = null;
    release?.call();
  }
}

/// Redux actions access shared dependencies through the global dispatcher.
class AcquireSourceCacheLeaseAction extends AsyncGlobalActionWithResult<SourceCacheLease> {
  @override
  Future<SourceCacheLease> reduce() => ref.read(sourceCacheLeaseProvider).acquire();
}
