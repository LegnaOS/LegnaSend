import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/util/api/host_native_tasks.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';

import '../util/send_queue_test.dart' show file;

void main() {
  test('unobserved restored cancel and same-phase resume rejects the previous API task version', () async {
    final gates = <Completer<SessionStatus?>>[];
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) {},
      execute: (_) {
        final gate = Completer<SessionStatus?>();
        gates.add(gate);
        return gate.future;
      },
    );
    final recovered = SendJob(
      id: 'stable-recovery-id',
      target: Device.empty.copyWith(fingerprint: 'target'),
      files: [file],
      restored: true,
      status: SendJobStatus.failed,
    );
    queue.restore([recovered]);
    queue.resume(recovered);
    final actions = <String>[];
    final manager = HostNativeTasks(
      readGeneration: () => 1,
      readTasks: () => [
        for (final job in queue.jobs)
          HostNativeTask(
            activity: TransferActivity(
              id: job.id,
              direction: TransferDirection.send,
              phase: job.status == SendJobStatus.running ? TransferPhase.preparing : TransferPhase.canceled,
              peer: 'target',
              files: const [TransferActivityFile('name', 1, 0)],
            ),
            controlRevision: (job.status, job.attemptIndices, job.attemptRevision),
            actions: const ['cancel'],
          ),
      ],
      control: (task, action) async {
        actions.add(task.activity.id);
        queue.cancel(task.activity.id);
      },
    );
    Future<Map<String, dynamic>> call(String op, {Map<String, Object?>? change, String? taskId}) async =>
        jsonDecode(
              await manager.execute(
                request: jsonEncode({
                  'operation': 'nativeTasks.$op',
                  'principal': 'key',
                  'workspaces': ['*'],
                  'change': ?change,
                  'taskId': ?taskId,
                }),
                claim: () async => true,
              ),
            )
            as Map<String, dynamic>;
    final before = (await call('list'))['body'] as Map;
    final first = before['tasks'][0] as Map;
    expect(queue.jobs.single.attemptRevision, 1);
    expect(queue.jobs.single.attemptIndices, isNull);
    queue.cancel(recovered.id);
    gates.first.complete(null);
    await Future<void>.delayed(Duration.zero);
    queue.resume(queue.jobs.single);
    expect(queue.jobs.single.status, SendJobStatus.running);
    expect(queue.jobs.single.attemptRevision, 2);
    expect(queue.jobs.single.attemptIndices, isNull);
    // No API snapshot observed the terminal phase in between these two attempts.
    expect(
      (await call(
        'control',
        taskId: first['id'] as String,
        change: {'epoch': before['epoch'], 'version': first['version'], 'action': 'cancel'},
      ))['status'],
      409,
    );
    expect(actions, isEmpty);
    expect(queue.jobs.single.status, SendJobStatus.running);
    final current = queue.jobs.single;
    for (final copied in [
      current.withStatus(SendJobStatus.running),
      current.withRecovery(),
      current.withCheckpoints({}, {}),
      current.withAttempt([0]),
    ]) {
      expect(copied.attemptRevision, 2);
    }
    queue.cancel(recovered.id);
    gates.last.complete(null);
    await Future<void>.delayed(Duration.zero);
    queue.dispose();
  });
  test('resume increments current incarnation even when handed an old terminal copy', () async {
    final gate = Completer<SessionStatus?>();
    final queue = SendQueue(concurrency: 1, onChanged: (_) {}, abort: (_) {}, execute: (_) => gate.future);
    final target = Device.empty.copyWith(fingerprint: 'one-peer');
    queue.enqueue(target, [file]); // Keep recovered work queued before any execute callback.
    final original = SendJob(id: 'recovered', target: target, files: [file], restored: true, status: SendJobStatus.failed);
    queue.restore([original]);
    queue.resume(original);
    expect(() => queue.resume(original), throwsStateError);
    queue.cancel(original.id);
    queue.resume(original);
    expect(queue.jobs.last.attemptRevision, 2);
    queue.dispose();
    gate.complete(null);
    await Future<void>.delayed(Duration.zero);
  });
}
