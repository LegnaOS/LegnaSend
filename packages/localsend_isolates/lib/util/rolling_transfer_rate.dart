/// Recent payload throughput, not a whole-session average or link bandwidth.
/// Call at a bounded cadence (the UI uses 500 ms) with a monotonic timestamp.
class RollingTransferRate {
  static const windowMs = 3000;
  static const minimumMs = 250;
  final _samples = <({int time, int bytes})>[];

  int? sample({required int bytes, required int nowMs}) {
    bytes = bytes < 0 ? 0 : bytes;
    if (_samples.isNotEmpty && (nowMs < _samples.last.time || bytes < _samples.last.bytes)) _samples.clear();
    if (_samples.isNotEmpty && nowMs == _samples.last.time) return null;
    _samples.add((time: nowMs, bytes: bytes));
    // Keep the sample immediately before the window boundary for sparse updates.
    while (_samples.length > 2 && _samples[1].time <= nowMs - windowMs) {
      _samples.removeAt(0);
    }
    // Defensive bound even when a caller ignores the documented sampling cadence.
    while (_samples.length > 32) {
      _samples.removeAt(1);
    }
    final elapsed = nowMs - _samples.first.time;
    return elapsed < minimumMs ? null : ((bytes - _samples.first.bytes) * 1000 / elapsed).round();
  }
}
