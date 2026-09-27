import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  test('a resumed recovered task failing before session creation is a fresh discoverable result', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final acknowledged = container.notifier(acknowledgedTransferResultsProvider);
    final attemptDone = Completer<void>();
    final queue = SendQueue(
      execute: (_) async => throw StateError('source disappeared before prepare'),
      abort: (_) {},
      onChanged: (jobs) {
        if (jobs.single.attemptRevision == 1 && jobs.single.status == SendJobStatus.failed) attemptDone.complete();
      },
    );
    addTearDown(queue.dispose);
    queue.restore([
      SendJob(id: 'recovered', target: Device.empty, files: [queuedFile('source', 100)], status: SendJobStatus.failed, restored: true),
    ]);
    List<TransferActivity> aggregate() => collectTransferActivities(jobs: queue.jobs, sends: {}, receive: null, progress: FileTransferNotifier());
    final old = aggregate().single;
    acknowledged.acknowledge([old]);
    queue.resume(queue.jobs.single);
    await attemptDone.future;
    final retried = aggregate().single;
    expect(retried.key, old.key);
    expect(retried.phase, TransferPhase.failed);
    expect(retried.job!.attemptRevision, 1);
    expect(retried.resultKey, isNot(old.resultKey));
    expect(container.read(acknowledgedTransferResultsProvider), isNot(contains(retried.resultKey)));
    expect(retried.error, contains('source disappeared'));
  });
  test('acknowledgements track current retained terminal results instead of leaking every old browser response', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final acknowledged = container.notifier(acknowledgedTransferResultsProvider);
    const native = TransferActivity(id: 'native', direction: TransferDirection.receive, phase: TransferPhase.succeeded, peer: 'Peer', files: []);
    for (var index = 0; index < 1000; index++) {
      acknowledged.acknowledge([
        native,
        TransferActivity(
          id: 'response-$index',
          kind: TransferActivityKind.webResponse,
          direction: TransferDirection.send,
          phase: TransferPhase.succeeded,
          peer: 'Browser',
          files: [],
        ),
      ]);
    }
    expect(container.read(acknowledgedTransferResultsProvider).length, 2);
    expect(container.read(acknowledgedTransferResultsProvider), {native.resultKey, 'webResponse:send:response-999:succeeded'});
  });
}
