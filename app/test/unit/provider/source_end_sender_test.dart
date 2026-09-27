import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../fixtures/transfer_fixtures.dart';

class _Queue extends SendQueueNotifier {
  final SendJob job;
  _Queue(this.job);
  @override
  List<SendJob> init() => [job];
}

class _Sender extends SendNotifier {
  _Sender(IsolateHttpUploadActionResult Function(IsolateHttpUploadFilesAction) upload, void Function(IsolateHttpSourceEndAckAction) ack)
    : super(uploadFiles: upload, ackSourceEnd: ack, cancelUpload: (_) {});
  void seed(SendSessionState value) => state = {value.sessionId: value};
}

void main() {
  const uuid = Uuid();
  for (final scenario in ['ack', 'failure', 'late', 'small']) {
    test('real sender source-end $scenario', () async {
      final id = uuid.v4(), resumeKey = uuid.v4(), ackId = uuid.v4();
      final original = outgoing(id, size: scenario == 'small' ? 1024 : 1024 * 1024).copyWith(background: false);
      final session = original.copyWith(
        target: original.target.copyWith(fingerprint: 'peer'),
        files: {'out': original.files['out']!.copyWith(resumeKey: resumeKey)},
      );
      String? disk;
      bool block = false, fail = false;
      final gate = Completer<void>();
      final store = SourceEndStore(
        read: () async => disk,
        write: (data) async {
          if (block) await gate.future;
          if (fail) throw StateError('write');
          disk = data;
        },
      );
      final stream = StreamController<HttpUploadEvent>();
      final uploads = <IsolateHttpUploadFilesAction>[], acks = <IsolateHttpSourceEndAckAction>[];
      final sender = _Sender((action) {
        uploads.add(action);
        return IsolateHttpUploadActionResult(taskId: 27, events: stream.stream);
      }, acks.add);
      final container = RefenaContainer(
        overrides: [
          sourceEndStoreProvider.overrideWithValue(store),
          sendProvider.overrideWithNotifier((_) => sender),
          sendQueueProvider.overrideWithNotifier(
            (_) => _Queue(SendJob(id: id, target: session.target, files: [queuedFile('out', 1024 * 1024)], resumeKeys: [resumeKey])),
          ),
        ],
      );
      container.read(sendProvider);
      sender.seed(session);
      container.notifier(fileTransferProvider).setStatus(sessionId: id, fileId: 'out', status: FileStatus.queue);
      final done = sender.sendFile(sessionId: id, file: session.files['out']!, isRetry: false);
      for (var i = 0; i < 20 && uploads.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(uploads, hasLength(1));
      expect(uploads.single.files.single.enableSourceEnd, scenario != 'small');
      if (scenario != 'small') {
        if (scenario == 'late') {
          await container.notifier(sourceEndProvider).endJob(id);
          sender.cancelSession(id);
        }
        block = scenario == 'ack';
        fail = scenario == 'failure';
        stream.add(
          HttpUploadSourceEndGrantEvent(
            fileId: 'out',
            ackId: ackId,
            grant: SourceEndGrant(version: 1, grantId: uuid.v4(), round: uuid.v4(), token: 'A' * 43, expiresAtUnixMs: 2000000000000),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        if (block) {
          expect(acks, isEmpty);
          expect(disk, isNot(contains('A' * 43)));
          gate.complete();
        }
        for (var i = 0; i < 20 && acks.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(acks, hasLength(1));
        expect(acks.single.persisted, scenario != 'failure');
        expect(acks.single.uploadTaskId, 27);
        expect(acks.single.ackId, ackId);
        if (scenario == 'late') {
          expect(store.pending(), hasLength(1));
          expect(jsonEncode(store.notices()), isNot(contains('A' * 43)));
        }
      } else {
        expect(disk, isNull);
      }
      await stream.close();
      await done;
      container.disposeContainer();
    });
  }
}
