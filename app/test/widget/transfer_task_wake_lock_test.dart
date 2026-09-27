import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/ui/transfer_wake_lock.dart';
import 'package:localsend_app/widget/transfer_wake_lock_scope.dart';

void main() {
  testWidgets('foreground task lease survives route content replacement and ends with task', (tester) async {
    final calls = <bool>[];
    final manager = TransferWakeLock(toggle: (value) async => calls.add(value));
    Future<void> mount(bool active, String page) async {
      await tester.pumpWidget(
        TransferWakeLockScope(
          active: active,
          manager: manager,
          child: Text(page, textDirection: TextDirection.ltr),
        ),
      );
      await manager.settled;
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mount(true, 'Progress');
    await mount(true, 'Home');
    expect(calls, [true]);
    await mount(false, 'Home');
    expect(calls, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suspension releases task demand and resume reasserts current state', (tester) async {
    final calls = <bool>[];
    final manager = TransferWakeLock(toggle: (value) async => calls.add(value));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(TransferWakeLockScope(active: true, manager: manager, child: const SizedBox()));
    await manager.settled;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await manager.settled;
    expect(calls.last, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await manager.settled;
    expect(calls.last, true);
    calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await manager.settled;
    expect(calls, [true]);
    await tester.pumpWidget(const SizedBox());
    await manager.settled;
    expect(calls.last, false);
  });

  testWidgets('inactive waiting task does not acquire a lease and other owners remain intact', (tester) async {
    final calls = <bool>[];
    final manager = TransferWakeLock(toggle: (value) async => calls.add(value));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(TransferWakeLockScope(active: false, manager: manager, child: const SizedBox()));
    await manager.settled;
    expect(calls, isEmpty);
    final page = manager.acquire();
    await tester.pumpWidget(TransferWakeLockScope(active: true, manager: manager, child: const SizedBox()));
    await manager.settled;
    await tester.pumpWidget(const SizedBox());
    await manager.settled;
    expect(calls, [true]);
    page.release();
    await manager.settled;
    expect(calls, [true, false]);
  });

  test('resume refresh remains ordered behind an in-flight native toggle', () async {
    final calls = <bool>[], started = Completer<void>(), finish = Completer<void>();
    final manager = TransferWakeLock(
      toggle: (enabled) async {
        calls.add(enabled);
        if (calls.length == 1) {
          started.complete();
          await finish.future;
        }
      },
    );
    final lease = manager.acquire();
    await started.future;
    manager.refresh();
    finish.complete();
    await manager.settled;
    expect(calls, [true, true]);
    lease.release();
    await manager.settled;
    expect(calls.last, false);
  });
}
