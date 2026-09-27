import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import 'workspace_transfer_activity_test.dart' show workspaceRecord;

String _snapshot(String id, {String phase = 'transferring'}) => jsonEncode([workspaceRecord(id, bytes: 100, phase: phase)]);

void main() {
  for (final phase in ['succeeded', 'failed', 'canceled']) {
    testWidgets('stopped publication automatically resolves $phase without a running listener', (tester) async {
      var calls = 0;
      var snapshot = _snapshot('old');
      final notifier = WebTransferActivityNotifier(
        loadSnapshot: () async {
          calls++;
          return snapshot;
        },
      );
      final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
      addTearDown(container.disposeContainer);
      container.read(webTransferActivityProvider);
      notifier.apply(snapshot, generation: 1);
      notifier.stopped(generation: 2, finalSnapshot: snapshot, observe: true);
      await tester.pump();
      expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
      expect(await notifier.cancel('old'), false);
      snapshot = _snapshot('old', phase: phase);
      await tester.pump(const Duration(milliseconds: 500));
      expect(container.read(webTransferActivityProvider).single.phase.name, phase);
      expect(container.read(webTransferActivityProvider).single.transferredBytes, 100);
      expect(calls, 2);
      await tester.pump(const Duration(hours: 2));
      expect(calls, 2, reason: 'No idle polling after all real outcomes are known');
    });
  }

  testWidgets('unknown empty stop retries with bounded backoff then recovers unseen publication', (tester) async {
    var calls = 0;
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () async {
        calls++;
        if (calls <= 2) throw StateError('temporarily unavailable');
        return _snapshot('not-previously-polled', phase: 'succeeded');
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    notifier.stopped(generation: 2, observe: true);
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 999));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 2);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(calls, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 3);
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.succeeded);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 3);
  });

  testWidgets('stop then rapid new listener remains single flight and uses shared outcomes', (tester) async {
    final requests = <Completer<String>>[];
    var canceled = 0;
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () {
        final next = Completer<String>();
        requests.add(next);
        return next.future;
      },
      cancelRequest: (_) async {
        canceled++;
        return true;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    notifier.apply(_snapshot('old'), generation: 1);
    notifier.startPolling(generation: () => 1, isCurrent: () => true);
    notifier.stopped(generation: 2, finalSnapshot: _snapshot('old'), observe: true);
    notifier.startPolling(generation: () => 3, isCurrent: () => true);
    expect(requests.length, 1);
    requests.single.complete(_snapshot('old', phase: 'canceled'));
    await tester.pump();
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
    await tester.pump(const Duration(milliseconds: 500));
    expect(requests.length, 2);
    requests[1].complete(jsonEncode([workspaceRecord('old'), workspaceRecord('new')]));
    await tester.pump();
    expect(container.read(webTransferActivityProvider).map((task) => task.phase), [TransferPhase.unconfirmed, TransferPhase.transferring]);
    expect(await notifier.cancel('old', expectedGeneration: 3), false);
    expect(await notifier.cancel('new', expectedGeneration: 2), false);
    expect(await notifier.cancel('new', expectedGeneration: 3), true);
    expect(canceled, 1);
    await tester.pump(const Duration(milliseconds: 500));
    requests[2].complete(jsonEncode([workspaceRecord('old', bytes: 100, phase: 'succeeded'), workspaceRecord('new')]));
    await tester.pump();
    expect(container.read(webTransferActivityProvider).first.phase, TransferPhase.succeeded);
    notifier.stopPolling();
  });

  for (final discoveredByFinal in [true, false]) {
    testWidgets('previously unseen stopped publication stays retired after restart (final=$discoveredByFinal)', (tester) async {
      var dispatched = 0;
      final snapshot = _snapshot('unseen-before-stop');
      final notifier = WebTransferActivityNotifier(
        loadSnapshot: () async => snapshot,
        cancelRequest: (_) async {
          dispatched++;
          return true;
        },
      );
      final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
      addTearDown(container.disposeContainer);
      container.read(webTransferActivityProvider);
      notifier.stopped(generation: 1, finalSnapshot: discoveredByFinal ? snapshot : null, observe: true);
      await tester.pump();
      expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
      notifier.startPolling(generation: () => 2, isCurrent: () => true);
      await tester.pump();
      expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
      expect(await notifier.cancel('unseen-before-stop', expectedGeneration: 2), false);
      expect(dispatched, 0);
      notifier.stopPolling();
    });
  }

  testWidgets('no timeout discards pending result and dispose stops the single observer', (tester) async {
    var calls = 0;
    final pending = Completer<String>();
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () async {
        calls++;
        return pending.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    container.read(webTransferActivityProvider);
    notifier.stopped(generation: 1, finalSnapshot: _snapshot('disk-busy'), observe: true);
    await tester.pump();
    await tester.pump(const Duration(days: 2));
    expect(calls, 1);
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
    container.disposeContainer();
    pending.complete(_snapshot('disk-busy', phase: 'succeeded'));
    await tester.pump(const Duration(days: 2));
    expect(calls, 1);
  });

  test('terminal replay across generations cannot regress or reset an acknowledgement', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(_snapshot('done', phase: 'succeeded'), generation: 1);
    container.notifier(acknowledgedTransferResultsProvider).acknowledge(container.read(webTransferActivityProvider));
    final acknowledged = container.read(acknowledgedTransferResultsProvider).single;
    notifier.stopped(generation: 2, finalSnapshot: _snapshot('done'));
    notifier.apply(_snapshot('done'), generation: 3);
    final result = container.read(webTransferActivityProvider).single;
    expect(result.phase, TransferPhase.succeeded);
    expect(result.resultKey, acknowledged);
    expect(container.read(acknowledgedTransferResultsProvider), {acknowledged});
  });

  test('bounded stop replay preserves metadata without accumulating retired records', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    for (var generation = 0; generation < 270; generation++) {
      notifier.apply(_snapshot('task-$generation'), generation: generation * 2);
      notifier.stopped(generation: generation * 2 + 1, finalSnapshot: '[]');
      expect(container.read(webTransferActivityProvider).length, lessThanOrEqualTo(256));
    }
    expect(container.read(webTransferActivityProvider).last.workspaceName, 'Workspace');
  });
}
