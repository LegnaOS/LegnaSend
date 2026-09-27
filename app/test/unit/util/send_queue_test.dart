import 'dart:async';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:test/test.dart';

final file = CrossFile(
  name: 'a.txt',
  fileType: FileType.text,
  size: 1,
  thumbnail: null,
  asset: null,
  path: null,
  bytes: [65],
  lastModified: null,
  lastAccessed: null,
);
Device device(String id) => Device.empty.copyWith(fingerprint: id, ip: '10.0.0.1');
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('explicit endpoint stays snapshotted through queue state changes and retries', () async {
    const first = HttpChannel(host: '10.0.0.1', port: 53317, https: false);
    const second = HttpChannel(host: '10.8.0.1', port: 54443, https: true);
    final original = device('a').copyWith(port: first.port, channels: [first, second]);
    var discovered = original;
    final gate = Completer<SessionStatus?>();
    final targets = <Device>[];
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) {},
      execute: (job) {
        targets.add(resolveSendTarget(job.target, discovered, job.selectedChannel));
        return targets.length == 1 ? gate.future : Future.value(SessionStatus.finished);
      },
    );
    queue.enqueue(original, [file], selectedChannel: first);
    final queued = queue.enqueue(original, [file], selectedChannel: first);
    discovered = original.copyWith(ip: second.host, port: second.port, https: true, channels: [second, first]);
    gate.complete(SessionStatus.finished);
    await tick();
    expect(targets.map((target) => target.ip), [first.host, first.host]);
    final job = queue.jobs.firstWhere((job) => job.id == queued);
    expect(job.selectedChannel, first);
    queue.enqueue(job.target, job.files, selectedChannel: job.selectedChannel);
    await tick();
    expect(targets.last.ip, first.host);
    expect(queue.jobs.last.selectedChannel, first);
    queue.dispose();
  });
  test('queued unavailable explicit endpoint fails rather than trying another channel', () async {
    const first = HttpChannel(host: '10.0.0.1', port: 53317, https: false);
    const second = HttpChannel(host: '10.8.0.1', port: 53317, https: false);
    final original = device('a').copyWith(port: first.port, channels: [first, second]);
    final latest = original.copyWith(ip: second.host, channels: [second]);
    var executed = false;
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) {},
      execute: (job) async {
        resolveSendTarget(job.target, latest, job.selectedChannel);
        executed = true;
        return SessionStatus.finished;
      },
    );
    queue.enqueue(original, [file], selectedChannel: first);
    await tick();
    expect(executed, isFalse);
    expect(queue.jobs.single.status, SendJobStatus.failed);
    expect(queue.jobs.single.error, 'selected-channel-unavailable');
    expect(queue.jobs.single.selectedChannel, first);
    queue.dispose();
  });

  test('per-device FIFO, changed IP identity and bounded cross-device concurrency', () async {
    final started = <SendJob>[];
    final gates = <Completer<SessionStatus?>>[];
    final queue = SendQueue(
      concurrency: 2,
      onChanged: (_) {},
      abort: (_) {},
      execute: (job) {
        started.add(job);
        final gate = Completer<SessionStatus?>();
        gates.add(gate);
        return gate.future;
      },
    );
    queue.enqueue(device('a'), [file]);
    queue.enqueue(device('a').copyWith(ip: '10.1.0.1'), [file]);
    queue.enqueue(device('b'), [file]);
    queue.enqueue(device('c'), [file]);
    expect(started.map((j) => j.target.fingerprint), ['a', 'b']);
    gates[0].complete(SessionStatus.finished);
    await tick();
    expect(started.map((j) => j.target.fingerprint), ['a', 'b', 'a']);
    gates[1].complete(SessionStatus.finished);
    gates[2].complete(SessionStatus.finished);
    await tick();
    expect(started.last.target.fingerprint, 'c');
    gates[3].complete(SessionStatus.finished);
    await tick();
    expect(queue.jobs.every((j) => j.status == SendJobStatus.succeeded), isTrue);
  });
  test('canceling a running task keeps the slot until its future drains', () async {
    final gates = <Completer<SessionStatus?>>[];
    final aborted = <String>[];
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (j) => aborted.add(j.id),
      execute: (_) {
        final gate = Completer<SessionStatus?>();
        gates.add(gate);
        return gate.future;
      },
    );
    final first = queue.enqueue(device('a'), [file]);
    queue.enqueue(device('a'), [file]);
    queue.cancel(first);
    expect(aborted, [first]);
    expect(gates.length, 1);
    gates.first.complete(SessionStatus.finished);
    await tick();
    expect(queue.jobs.first.status, SendJobStatus.canceled);
    expect(gates.length, 2);
    gates.last.complete(SessionStatus.finished);
    await tick();
  });
  test('remote cancellation must finish before starting the next task', () async {
    final transfer = Completer<SessionStatus?>();
    final canceled = Completer<void>();
    var calls = 0;
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) => canceled.future,
      execute: (_) {
        calls++;
        return calls == 1 ? transfer.future : Future.value(SessionStatus.finished);
      },
    );
    final first = queue.enqueue(device('a'), [file]);
    queue.enqueue(device('a'), [file]);
    queue.cancel(first);
    transfer.complete(null);
    await tick();
    expect(calls, 1);
    canceled.complete();
    await tick();
    expect(calls, 2);
  });
  test('failed task releases the device and never blocks subsequent work', () async {
    var count = 0;
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) {},
      execute: (_) async {
        if (count++ == 0) throw StateError('offline');
        return SessionStatus.finished;
      },
    );
    queue.enqueue(device('a'), [file]);
    queue.enqueue(device('a'), [file]);
    await tick();
    expect(queue.jobs.map((j) => j.status), [SendJobStatus.failed, SendJobStatus.succeeded]);
  });
  test('file list and in-memory bytes are snapshotted, queued cancellation sends nothing', () async {
    final gate = Completer<SessionStatus?>();
    var calls = 0;
    final queue = SendQueue(
      onChanged: (_) {},
      abort: (_) {},
      execute: (_) {
        calls++;
        return gate.future;
      },
    );
    final bytes = [66];
    final selected = [file.copyWith(bytes: bytes)];
    queue.enqueue(device('a'), selected);
    final second = queue.enqueue(device('a'), selected);
    selected.clear();
    bytes[0] = 67;
    expect(queue.jobs.first.files.single.bytes, [66]);
    queue.cancel(second);
    gate.complete(SessionStatus.finished);
    await tick();
    expect(calls, 1);
    expect(queue.jobs.last.status, SendJobStatus.canceled);
  });
}
