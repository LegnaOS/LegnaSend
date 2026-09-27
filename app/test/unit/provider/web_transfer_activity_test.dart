import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

Map<String, Object?> record(String id, {String phase = 'transferring', int bytes = 17, int? total = 100}) => {
  'id': id,
  'sessionId': 'browser',
  'peer': '127.0.0.1',
  'name': 'folder/file.txt',
  'total': total,
  'transferred': bytes,
  'phase': phase,
};
void main() {
  testWidgets('snapshot polling has one in-flight request and schedules only after consumption', (tester) async {
    final requests = <Completer<String>>[];
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () {
        final next = Completer<String>();
        requests.add(next);
        return next.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    container.read(webTransferActivityProvider);
    notifier.startPolling(generation: () => 1, isCurrent: () => true);
    expect(requests.length, 1);
    await tester.pump(const Duration(minutes: 3));
    expect(requests.length, 1);
    requests[0].complete(jsonEncode([record('first')]));
    await tester.pump();
    expect(container.read(webTransferActivityProvider).single.id, 'first');
    await tester.pump(const Duration(milliseconds: 499));
    expect(requests.length, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests.length, 2);
    notifier.stopped(generation: 2);
    requests[1].complete(jsonEncode([record('late')]));
    await tester.pump(const Duration(seconds: 3));
    expect(requests.length, 2);
    expect(container.read(webTransferActivityProvider).single.id, 'first');
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
    container.disposeContainer();
  });
  testWidgets('replacement listener waits for prior pull, ignores stale result and disposes cleanly', (tester) async {
    final requests = <Completer<String>>[];
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () {
        final next = Completer<String>();
        requests.add(next);
        return next.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    container.read(webTransferActivityProvider);
    notifier.startPolling(generation: () => 1, isCurrent: () => true);
    notifier.startPolling(generation: () => 2, isCurrent: () => true);
    expect(requests.length, 1);
    requests[0].complete(jsonEncode([record('old')]));
    await tester.pump();
    expect(container.read(webTransferActivityProvider), isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(requests.length, 2);
    requests[1].complete(jsonEncode([record('new')]));
    await tester.pump();
    expect(container.read(webTransferActivityProvider).single.id, 'new');
    await tester.pump(const Duration(milliseconds: 500));
    expect(requests.length, 3);
    container.disposeContainer();
    requests[2].complete(jsonEncode([record('disposed')]));
    await tester.pump(const Duration(seconds: 10));
    expect(requests.length, 3);
    expect(tester.takeException(), isNull);
  });
  testWidgets('polling preserves bytes on errors then recovers without overlapping requests', (tester) async {
    var calls = 0;
    var current = true;
    final notifier = WebTransferActivityNotifier(
      loadSnapshot: () async {
        calls++;
        if (calls == 1) throw StateError('ended snapshot');
        return jsonEncode([record('recovered')]);
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    container.read(webTransferActivityProvider);
    notifier.apply(jsonEncode([record('retained')]), generation: 1);
    notifier.startPolling(generation: () => 1, isCurrent: () => current);
    await tester.pump();
    expect(container.read(webTransferActivityProvider).single.id, 'retained');
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, 2);
    expect(container.read(webTransferActivityProvider).single.id, 'recovered');
    current = false;
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
    container.disposeContainer();
  });
  test('actual response bytes, unknown ZIP length and native namespace remain distinct', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(jsonEncode([record('same'), record('zip', total: null, bytes: 4096)]), generation: 2);
    final values = container.read(webTransferActivityProvider);
    expect(values.first.key, 'webResponse:send:same');
    expect(values.first.transferredBytes, 17);
    expect(values.last.transferredBytes, 4096);
    expect(values.last.totalKnown, false);
    expect(activeTransferProgress(values, TransferDirection.send), isNull);
    notifier.apply(jsonEncode([record('old', bytes: 0)]), generation: 1);
    expect(container.read(webTransferActivityProvider).first.id, 'same');
  });
  test('malformed or duplicate snapshots are atomic and stop retains real bytes', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(jsonEncode([record('one')]), generation: 1);
    for (final input in [
      jsonEncode([record('same'), record('same')]),
      jsonEncode([record('bad', bytes: 101)]),
      '{}',
    ]) {
      expect(() => notifier.apply(input, generation: 2), throwsFormatException);
      expect(container.read(webTransferActivityProvider).single.id, 'one');
    }
    notifier.stopped(generation: 2);
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
    expect(container.read(webTransferActivityProvider).single.transferredBytes, 17);
    notifier.apply(jsonEncode([record('one', phase: 'succeeded', bytes: 100)]), generation: 1);
    expect(container.read(webTransferActivityProvider).single.phase, TransferPhase.unconfirmed);
  });
  test('terminal acknowledgement remains separate from native results and active responses', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(jsonEncode([record('done', phase: 'succeeded', bytes: 100), record('running')]), generation: 1);
    container.notifier(acknowledgedTransferResultsProvider).acknowledge(container.read(webTransferActivityProvider));
    expect(container.read(acknowledgedTransferResultsProvider), {'webResponse:send:done:succeeded'});
    expect(container.read(webTransferActivityProvider).length, 2);
  });
}
