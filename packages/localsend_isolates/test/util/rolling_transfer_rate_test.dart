import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/util/rolling_transfer_rate.dart';

void main() {
  test('small-file progress is measurable without a minimum byte threshold', () {
    final rate = RollingTransferRate();
    expect(rate.sample(bytes: 0, nowMs: 0), isNull);
    expect(rate.sample(bytes: 500, nowMs: 500), 1000);
    expect(rate.sample(bytes: 1000, nowMs: 1000), 1000);
  });
  test('a stalled transfer decays to zero instead of retaining lifetime average', () {
    final rate = RollingTransferRate()..sample(bytes: 0, nowMs: 0);
    rate.sample(bytes: 1000000, nowMs: 500);
    for (var now = 1000; now <= 3500; now += 500) {
      rate.sample(bytes: 1000000, nowMs: now);
    }
    expect(rate.sample(bytes: 1000000, nowMs: 4000), 0);
  });
  test('retries and nonmonotonic timestamps restart the measurement without negative or infinite speed', () {
    final rate = RollingTransferRate()..sample(bytes: 1000, nowMs: 1000);
    expect(rate.sample(bytes: 2000, nowMs: 1000), isNull);
    expect(rate.sample(bytes: 100, nowMs: 1500), isNull);
    expect(rate.sample(bytes: 300, nowMs: 2000), 400);
    expect(rate.sample(bytes: 400, nowMs: 2), isNull);
    expect(rate.sample(bytes: -1, nowMs: 3), isNull);
    expect(rate.sample(bytes: 0, nowMs: 1000), 0);
  });
}
