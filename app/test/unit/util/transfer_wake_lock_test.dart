import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/ui/transfer_wake_lock.dart';

void main() {
  test('multiple page leases enable once and only the last release disables', () async {
    final calls = <bool>[];
    final manager = TransferWakeLock(toggle: (enabled) async => calls.add(enabled));
    final send = manager.acquire(), receive = manager.acquire();
    await manager.settled;
    expect(calls, [true]);
    receive.release();
    receive.release();
    await manager.settled;
    expect(calls, [true]);
    send.release();
    send.release();
    await manager.settled;
    expect(calls, [true, false]);
  });

  test('release and reacquire before pending work starts does not flicker the lock', () async {
    final calls = <bool>[];
    final manager = TransferWakeLock(toggle: (enabled) async => calls.add(enabled));
    final old = manager.acquire();
    await manager.settled;
    old.release();
    final current = manager.acquire();
    await manager.settled;
    expect(calls, [true]);
    current.release();
    await manager.settled;
    expect(calls, [true, false]);
  });

  test('an in-flight old disable completes before a newly acquired page enables', () async {
    final calls = <bool>[], disableStarted = Completer<void>(), finishDisable = Completer<void>();
    var active = false;
    final manager = TransferWakeLock(
      toggle: (enabled) async {
        calls.add(enabled);
        if (!enabled) {
          if (!disableStarted.isCompleted) disableStarted.complete();
          await finishDisable.future;
        }
        active = enabled;
      },
    );
    final old = manager.acquire();
    await manager.settled;
    old.release();
    await disableStarted.future;
    final current = manager.acquire();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true, false]);
    finishDisable.complete();
    await manager.settled;
    expect(calls, [true, false, true]);
    expect(active, true);
    current.release();
    await manager.settled;
    expect(active, false);
  });

  test('a page disposed while enable is pending still releases after completion', () async {
    final entered = Completer<void>(), gate = Completer<void>(), calls = <bool>[];
    final manager = TransferWakeLock(
      toggle: (enabled) async {
        calls.add(enabled);
        if (enabled) {
          entered.complete();
          await gate.future;
        }
      },
    );
    final lease = manager.acquire();
    await entered.future;
    lease.release();
    gate.complete();
    await manager.settled;
    expect(calls, [true, false]);
  });

  test('platform and diagnostic failures do not poison later reconciliation', () async {
    final calls = <bool>[];
    var fail = true, errors = 0;
    final manager = TransferWakeLock(
      toggle: (enabled) async {
        calls.add(enabled);
        if (fail) throw StateError('native transition failed');
      },
      onError: (_, _) {
        errors++;
        throw StateError('diagnostic failed');
      },
    );
    final old = manager.acquire();
    await manager.settled;
    expect(errors, 1);
    fail = false;
    final current = manager.acquire();
    await manager.settled;
    expect(calls, [true, true]);
    old.release();
    await manager.settled;
    expect(calls, [true, true]);
    current.release();
    await manager.settled;
    expect(calls, [true, true, false]);
  });

  test('a failed disable is reconciled to enabled for a replacement lease', () async {
    final calls = <bool>[];
    var failDisable = true;
    final manager = TransferWakeLock(
      toggle: (enabled) async {
        calls.add(enabled);
        if (!enabled && failDisable) throw StateError('disable acknowledgement lost');
      },
    );
    final old = manager.acquire();
    await manager.settled;
    old.release();
    await manager.settled;
    final current = manager.acquire();
    await manager.settled;
    expect(calls, [true, false, true]);
    failDisable = false;
    current.release();
    await manager.settled;
    expect(calls, [true, false, true, false]);
  });
}
