import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:test/test.dart';

import '../../fixtures/transfer_fixtures.dart';

void main() {
  test('queue and session share one row; equal IDs in opposite directions stay distinct', () {
    final tasks = collectTransferActivities(
      jobs: [
        SendJob(id: 'same', target: Device.empty, files: [queuedFile('out', 100)], status: SendJobStatus.running),
      ],
      sends: {'same': outgoing('same')},
      receive: incoming('same'),
      progress: FileTransferNotifier(),
    );
    expect(tasks.map((t) => t.key), ['send:same', 'receive:same']);
    expect(tasks.every((t) => t.active), isTrue);
  });
  test('byte aggregation excludes checksum, waiting, queued and history progress', () {
    final progress = FileTransferNotifier()
      ..setStatus(sessionId: 'small', fileId: 'out', status: FileStatus.sending)
      ..setStatus(sessionId: 'large', fileId: 'out', status: FileStatus.sending)
      ..setProgress(sessionId: 'small', fileId: 'out', progress: .5)
      ..setProgress(sessionId: 'large', fileId: 'out', progress: .25)
      ..setProgress(sessionId: 'hash', fileId: 'out', progress: 1);
    final tasks = collectTransferActivities(
      jobs: [],
      sends: {
        'small': outgoing('small', size: 100),
        'large': outgoing('large', size: 300),
        'hash': outgoing('hash', status: SessionStatus.waiting, size: 900).copyWith(hashedFileCount: 0),
        'done': outgoing('done', status: SessionStatus.finished, size: 9999),
      },
      receive: incoming('receive', status: SessionStatus.waiting),
      progress: progress,
    );
    expect(activeTransferProgress(tasks, TransferDirection.send), closeTo(.3125, .0001));
    expect(activeTransferProgress(tasks, TransferDirection.receive), isNull);
    expect(tasks.firstWhere((t) => t.id == 'hash').transferredBytes, 0);
    expect(tasks.firstWhere((t) => t.id == 'hash').phase, TransferPhase.preparing);
    expect(tasks.last.needsAttention, isTrue);
  });
  test('completed hashing followed by rejection is not credited as sent bytes', () {
    final progress = FileTransferNotifier()
      ..setProgress(sessionId: 'rejected', fileId: 'out', progress: 1)
      ..setStatus(sessionId: 'real', fileId: 'out', status: FileStatus.sending)
      ..setProgress(sessionId: 'real', fileId: 'out', progress: .4);
    final tasks = collectTransferActivities(
      jobs: [],
      sends: {
        'rejected': outgoing('rejected', status: SessionStatus.declined),
        'real': outgoing('real'),
      },
      receive: null,
      progress: progress,
    );
    expect(tasks.first.phase, TransferPhase.failed);
    expect(tasks.first.transferredBytes, 0);
    expect(tasks.last.transferredBytes, 40);
  });
  test('failed and skipped files are never credited as successfully transferred', () {
    final progress = FileTransferNotifier()
      ..setStatus(sessionId: 'failed', fileId: 'out', status: FileStatus.failed)
      ..setProgress(sessionId: 'failed', fileId: 'out', progress: 1)
      ..setStatus(sessionId: 'skipped', fileId: 'out', status: FileStatus.skipped);
    final tasks = collectTransferActivities(
      jobs: [],
      sends: {
        'failed': outgoing('failed', status: SessionStatus.finishedWithErrors),
        'skipped': outgoing('skipped', status: SessionStatus.finished),
      },
      receive: null,
      progress: progress,
    );
    expect(tasks.first.transferredBytes, 0);
    expect(tasks.first.phase, TransferPhase.failed);
    expect(tasks.last.totalBytes, 0);
  });
  test('completed queue rows retain selected-file outcomes rather than offered totals', () {
    final progress = FileTransferNotifier()..setStatus(sessionId: 'done', fileId: 'out', status: FileStatus.skipped);
    final tasks = collectTransferActivities(
      jobs: [
        SendJob(id: 'done', target: Device.empty, files: [queuedFile('out', 100)], status: SendJobStatus.succeeded),
      ],
      sends: {'done': outgoing('done', status: SessionStatus.finished)},
      receive: null,
      progress: progress,
    );
    expect(tasks.single.phase, TransferPhase.succeeded);
    expect(tasks.single.totalBytes, 0);
    expect(tasks.single.transferredBytes, 0);
  });
  test('queue cancellation remains terminal while network cancellation drains', () {
    final tasks = collectTransferActivities(
      jobs: [
        SendJob(id: 'cancel', target: Device.empty, files: [queuedFile('out', 100)], status: SendJobStatus.canceled),
      ],
      sends: {'cancel': outgoing('cancel')},
      receive: null,
      progress: FileTransferNotifier(),
    );
    expect(tasks.single.phase, TransferPhase.canceled);
    expect(tasks.single.active, isFalse);
  });
  test('a new terminal result is not hidden by an older acknowledgement', () {
    final first = collectTransferActivities(
      jobs: [],
      sends: {'send': outgoing('send', status: SessionStatus.finishedWithErrors).copyWith(endTime: 1)},
      receive: null,
      progress: FileTransferNotifier(),
    ).single;
    final retried = collectTransferActivities(
      jobs: [],
      sends: {'send': outgoing('send', status: SessionStatus.finishedWithErrors).copyWith(endTime: 2)},
      receive: null,
      progress: FileTransferNotifier(),
    ).single;
    expect(first.key, retried.key);
    expect(first.resultKey, isNot(retried.resultKey));
  });
}
