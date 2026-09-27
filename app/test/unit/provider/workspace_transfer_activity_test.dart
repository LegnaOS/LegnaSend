import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

Map<String, Object?> workspaceRecord(
  String id, {
  String direction = 'receive',
  String operation = 'upload',
  int bytes = 25,
  String phase = 'transferring',
}) => {
  'id': id,
  'name': 'nested/file.bin',
  'peer': '192.168.1.5',
  'transferred': bytes,
  'total': 100,
  'phase': phase,
  'direction': direction,
  'operation': operation,
  'origin': 'browser',
  'workspaceId': 'workspace-id',
  'workspaceName': 'Workspace',
};
void main() {
  test('zero-byte files and directory creation are complete only after successful publication', () {
    for (final operation in ['upload', 'directory']) {
      for (final phase in TransferPhase.values) {
        final task = TransferActivity(
          id: 'empty',
          direction: TransferDirection.receive,
          phase: phase,
          peer: '',
          operation: operation,
          files: const [TransferActivityFile('empty', 0, 0)],
        );
        expect(task.progress, phase == TransferPhase.succeeded ? 1 : 0, reason: '$operation / ${phase.name}');
      }
    }
  });
  test('workspace directions metadata and exact bytes coexist, and stopped retains metadata', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(jsonEncode([workspaceRecord('up'), workspaceRecord('down', direction: 'send', operation: 'archive')]), generation: 1);
    final tasks = container.read(webTransferActivityProvider);
    expect(tasks.map((task) => task.key), ['webResponse:receive:up', 'webResponse:send:down']);
    expect(tasks.first.workspaceId, 'workspace-id');
    expect(tasks.first.transferredBytes, 25);
    expect(activeTransferProgress(tasks, TransferDirection.receive), .25);
    notifier.stopped(generation: 2);
    final stopped = container.read(webTransferActivityProvider).first;
    expect(stopped.phase, TransferPhase.unconfirmed);
    expect(stopped.direction, TransferDirection.receive);
    expect(stopped.operation, 'upload');
    expect(stopped.origin, 'browser');
    expect(stopped.workspaceName, 'Workspace');
    expect(stopped.transferredBytes, 25);
  });
  test('metadata parsing is bounded atomic and accepts the core maximum Unicode source name', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(webTransferActivityProvider);
    notifier.apply(jsonEncode([workspaceRecord('valid')]), generation: 1);
    final previous = container.read(webTransferActivityProvider);
    for (final mutation in [
      {'direction': 'both'},
      {'direction': null},
      {'direction': 'send'},
      {'origin': 'unknown'},
      {'origin': 1},
      {'operation': 'execute'},
      {'operation': null},
      {'workspaceId': []},
      {'workspaceName': 1},
      {'workspaceName': null},
      {'workspaceName': 'x' * 513},
      {'name': 'x' * 8193},
      {'transferred': 101},
      {'transferred': 1.0},
    ]) {
      expect(
        () => notifier.apply(
          jsonEncode([
            workspaceRecord('first'),
            {...workspaceRecord('bad'), ...mutation},
          ]),
          generation: 2,
        ),
        throwsFormatException,
      );
      expect(container.read(webTransferActivityProvider), same(previous));
    }
    expect(() => notifier.apply(' ' * (8 * 1024 * 1024 + 1), generation: 2), throwsFormatException);
    notifier.apply(
      jsonEncode([
        {...workspaceRecord('unicode'), 'name': '😀' * 4096},
      ]),
      generation: 2,
    );
    expect(container.read(webTransferActivityProvider).single.files.single.name.length, 8192);
    final maximal = [
      for (var index = 0; index < 256; index++) {...workspaceRecord('id-$index'), 'name': '😀' * 4096},
    ];
    notifier.apply(jsonEncode(maximal), generation: 3);
    expect(container.read(webTransferActivityProvider).length, 256);
    expect(() => notifier.apply(jsonEncode([...maximal, workspaceRecord('extra')]), generation: 4), throwsFormatException);
  });
  test('single-request cancel is coalesced, stale generations ignored, and only core terminal snapshot ends the task', () async {
    final requests = <String>[];
    final gate = Completer<bool>();
    final notifier = WebTransferActivityNotifier(
      cancelRequest: (id) {
        requests.add(id);
        return gate.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    notifier.apply(jsonEncode([workspaceRecord('one'), workspaceRecord('two')]), generation: 1);
    final first = notifier.cancel('one', expectedGeneration: 1);
    final duplicate = notifier.cancel('one', expectedGeneration: 1);
    expect(identical(first, duplicate), true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, ['one']);
    expect(container.read(webTransferActivityProvider).every((task) => task.active), true);
    gate.complete(true);
    expect(await first, true);
    expect(await notifier.cancel('one', expectedGeneration: 1), true);
    expect(requests, ['one']);
    notifier.apply(jsonEncode([workspaceRecord('one', phase: 'canceled'), workspaceRecord('two')]), generation: 1);
    expect(await notifier.cancel('one', expectedGeneration: 1), false);
    notifier.apply(jsonEncode([workspaceRecord('one')]), generation: 2);
    expect(await notifier.cancel('one', expectedGeneration: 1), false);
    expect(requests, ['one']);
  });
  test('stop and replacement in the cancellation scheduling turn dispatch no old command', () async {
    final requests = <String>[];
    final notifier = WebTransferActivityNotifier(
      cancelRequest: (id) async {
        requests.add(id);
        return true;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    notifier.apply(jsonEncode([workspaceRecord('same')]), generation: 1);
    final pending = notifier.cancel('same');
    notifier.stopped(generation: 2);
    notifier.apply(jsonEncode([workspaceRecord('same'), workspaceRecord('new-after-stop')]), generation: 3);
    expect(await pending, false);
    expect(requests, isEmpty);
    final tasks = container.read(webTransferActivityProvider);
    expect(tasks.singleWhere((task) => task.id == 'same').phase, TransferPhase.unconfirmed);
    expect(tasks.singleWhere((task) => task.id == 'new-after-stop').active, true);
    expect(await notifier.cancel('same'), false);
    expect(await notifier.cancel('new-after-stop'), true);
    expect(requests, ['new-after-stop']);
  });
  test('synchronous cancel failures remain retryable and a late completion cannot claim a new listener', () async {
    var calls = 0;
    final gate = Completer<bool>();
    final notifier = WebTransferActivityNotifier(
      cancelRequest: (_) {
        if (++calls == 1) throw StateError('bridge failed');
        return gate.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => notifier)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    notifier.apply(jsonEncode([workspaceRecord('one')]), generation: 1);
    await expectLater(notifier.cancel('one'), throwsStateError);
    final pending = notifier.cancel('one');
    await Future<void>.delayed(Duration.zero);
    notifier.stopped(generation: 2);
    notifier.apply(jsonEncode([workspaceRecord('one'), workspaceRecord('new-listener-task')]), generation: 3);
    gate.complete(true);
    expect(await pending, false);
    final tasks = container.read(webTransferActivityProvider);
    expect(tasks.singleWhere((task) => task.id == 'one').phase, TransferPhase.unconfirmed);
    expect(tasks.singleWhere((task) => task.id == 'new-listener-task').active, true);
    expect(await notifier.cancel('one'), false);
    expect(calls, 2);
    expect(await notifier.cancel('new-listener-task'), true);
    expect(calls, 3);
  });
}
