import 'dart:io';

import 'package:localsend_isolates/util/ios_receive_scope.dart';

typedef ReceiveSourceEndScopeReply = Future<bool> Function({required String requestId, required bool granted});

/// One listener's internal source-end authorization. The captured reply belongs
/// to that listener, never whichever server happens to be current after await.
class ReceiveSourceEndScopeHandler {
  final ReceiveSourceEndScopeReply reply;
  final bool Function() isCurrent;
  final Future<IosReceiveScopeLease?> Function(String) acquire;
  final bool supported;

  ReceiveSourceEndScopeHandler({
    required this.reply,
    required this.isCurrent,
    Future<IosReceiveScopeLease?> Function(String)? acquire,
    bool? supported,
  }) : acquire = acquire ?? acquireIosReceiveMaintenanceScope,
       supported = supported ?? Platform.isIOS;

  /// Call without blocking the event stream. Stop/replacement closes admission,
  /// but MUST NOT cancel a granted responder or release its scope before drain.
  Future<void> handle(String requestId, String directory) async {
    if (!supported || !isCurrent()) {
      await reply(requestId: requestId, granted: false);
      return;
    }
    IosReceiveScopeLease? lease;
    try {
      try {
        lease = await acquire(directory);
      } catch (_) {
        // Busy, revoked and unavailable providers all deny, without bare paths.
        await reply(requestId: requestId, granted: false);
        return;
      }
      final granted = lease != null && lease.path == directory && isCurrent();
      // A true reply's Future is a CORE WORKER COMPLETION acknowledgement, not
      // just receipt of a permission decision. Keep the accessor alive through
      // false/stale replies and exceptional completion as well.
      await reply(requestId: requestId, granted: granted);
    } finally {
      // No timeout and no listener-lifecycle cancellation. Release errors remain
      // observable by the event owner instead of pretending the scope closed.
      await lease?.release();
    }
  }
}
