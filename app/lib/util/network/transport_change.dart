/// Persist before interrupting a listener, restoring both sides on failure.
/// Callers serialize this transaction with their server lifecycle.
Future<void> applyTransportChange({
  required bool previous,
  required bool next,
  required Future<void> Function(bool) persist,
  required Future<void> Function() apply,
  required Future<void> Function() restore,
}) async {
  await persist(next);
  try {
    await apply();
  } catch (error, stack) {
    var restored = true;
    try {
      await persist(previous);
    } catch (_) {
      restored = false;
    }
    try {
      await restore();
    } catch (_) {
      restored = false;
    }
    if (!restored) throw StateError('Transport update failed; restoration is incomplete');
    Error.throwWithStackTrace(error, stack);
  }
}
