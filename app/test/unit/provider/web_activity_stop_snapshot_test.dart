import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import 'workspace_transfer_activity_test.dart' show workspaceRecord;

void main() {
  test('server stop imports a published final outcome missed by periodic observation', () async {
    final finalSnapshot = jsonEncode([workspaceRecord('published', bytes: 100, phase: 'succeeded')]);
    final server = ServerService(stopListenerWithActivity: () async => finalSnapshot);
    final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
    addTearDown(container.disposeContainer);
    container.read(serverProvider);
    final activities = container.notifier(webTransferActivityProvider);
    activities.apply(jsonEncode([workspaceRecord('published')]), generation: 0);
    await server.stopServer();
    final result = container.read(webTransferActivityProvider).single;
    expect(result.phase, TransferPhase.succeeded);
    expect(result.transferredBytes, 100);
    expect(result.workspaceName, 'Workspace');
  });
  for (final unavailable in [false, true]) {
    test('final ${unavailable ? 'unavailable' : 'still publishing'} snapshot is explicit uncertainty, not cancellation', () async {
      final server = ServerService(
        stopListenerWithActivity: () async => unavailable ? null : jsonEncode([workspaceRecord('publishing', bytes: 100)]),
      );
      final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
      addTearDown(container.disposeContainer);
      container.read(serverProvider);
      final activities = container.notifier(webTransferActivityProvider);
      activities.apply(jsonEncode([workspaceRecord('publishing'), workspaceRecord('known', phase: 'failed')]), generation: 0);
      await server.stopServer();
      final result = container.read(webTransferActivityProvider).first;
      expect(result.phase, TransferPhase.unconfirmed);
      expect(result.active, false);
      expect(result.needsAttention, true);
      expect(result.workspaceName, 'Workspace');
      expect(await activities.cancel(result.id), false);
      if (unavailable) expect(container.read(webTransferActivityProvider).last.phase, TransferPhase.failed);
    });
  }
  test('final trimmed history keeps missing observed activity unknown within 256 records', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final activities = container.notifier(webTransferActivityProvider);
    activities.apply(jsonEncode([workspaceRecord('missing')]), generation: 1);
    final finalSnapshot = jsonEncode([for (var index = 0; index < 256; index++) workspaceRecord('done-$index', bytes: 100, phase: 'succeeded')]);
    activities.stopped(generation: 2, finalSnapshot: finalSnapshot);
    final state = container.read(webTransferActivityProvider);
    expect(state.length, 256);
    expect(state.singleWhere((task) => task.id == 'missing').phase, TransferPhase.unconfirmed);
    expect(state.where((task) => task.phase == TransferPhase.succeeded).length, 255);
  });
  test('final known failure and cancellation remain authoritative; malformed final keeps prior successes', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final activities = container.notifier(webTransferActivityProvider);
    activities.apply(jsonEncode([workspaceRecord('one'), workspaceRecord('two')]), generation: 1);
    activities.stopped(
      generation: 2,
      finalSnapshot: jsonEncode([workspaceRecord('one', phase: 'failed'), workspaceRecord('two', phase: 'canceled')]),
    );
    expect(container.read(webTransferActivityProvider).map((task) => task.phase), [TransferPhase.failed, TransferPhase.canceled]);
    activities.apply(jsonEncode([workspaceRecord('success', bytes: 100, phase: 'succeeded'), workspaceRecord('active')]), generation: 3);
    activities.stopped(generation: 4, finalSnapshot: '[bad');
    expect(container.read(webTransferActivityProvider).map((task) => task.phase), [TransferPhase.succeeded, TransferPhase.unconfirmed]);
    activities.stopped(generation: 2, finalSnapshot: '[]');
    expect(container.read(webTransferActivityProvider).length, 2);
  });
}
