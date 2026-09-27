import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/receive_scope_owner.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';

void main() {
  test('retire waits for late acquire and retained probe, then releases exactly once', () async {
    final acquire = Completer<IosReceiveScopeLease?>();
    final owner = ReceiveScopeOwner();
    var releases = 0;
    final probe = owner.retain();
    final pending = owner.acquire(() => acquire.future);
    var closed = false;
    final retired = owner.retire().then((_) => closed = true);
    expect(owner.active, false);
    expect(() => owner.retain(), throwsStateError);
    acquire.complete(IosReceiveScopeLease(leaseId: 'old', path: '/approved', release: (_) async => releases++));
    await pending;
    expect(owner.isExternal, true);
    expect(releases, 0);
    probe();
    probe();
    await retired;
    await owner.retire();
    expect(closed, true);
    expect(releases, 1);
  });
  test('all queued, writer and postprocess users must drain after replacement', () async {
    var oldReleases = 0, newReleases = 0;
    final old = ReceiveScopeOwner(), next = ReceiveScopeOwner();
    await old.acquire(() async => IosReceiveScopeLease(leaseId: 'old', path: '/old', release: (_) async => oldReleases++));
    final queued = old.retain(), writer = old.retain(), postprocess = old.retain();
    final retiring = old.retire();
    await next.acquire(() async => IosReceiveScopeLease(leaseId: 'next', path: '/next', release: (_) async => newReleases++));
    queued();
    writer();
    await Future<void>.delayed(Duration.zero);
    expect(oldReleases, 0);
    expect(newReleases, 0);
    postprocess();
    await retiring;
    expect(oldReleases, 1);
    expect(next.active, true);
    expect(newReleases, 0);
    await next.retire();
    expect(newReleases, 1);
  });
  test('acquire failure and sandbox have no fabricated lease release', () async {
    final failed = ReceiveScopeOwner();
    await expectLater(failed.acquire(() async => throw StateError('revoked')), throwsStateError);
    await failed.retire();
    expect(failed.isExternal, false);
    final sandbox = ReceiveScopeOwner();
    await sandbox.acquire(() async => null);
    expect(sandbox.isExternal, false);
    await sandbox.retire();
    await expectLater(sandbox.acquire(() async => throw StateError('should never run')), throwsStateError);
  });
  test('retire awaits native coordinator exit and surfaces release failure only once', () async {
    final owner = ReceiveScopeOwner();
    final closed = Completer<void>();
    var calls = 0;
    await owner.acquire(
      () async => IosReceiveScopeLease(
        leaseId: 'scope',
        path: '/scope',
        release: (_) {
          calls++;
          return closed.future;
        },
      ),
    );
    final first = owner.retire(), second = owner.retire();
    var drained = false;
    final waiting = first.then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(drained, false);
    closed.complete();
    await waiting;
    await second;
    expect(drained, true);
    final broken = ReceiveScopeOwner();
    var failedCalls = 0;
    await broken.acquire(
      () async => IosReceiveScopeLease(
        leaseId: 'scope',
        path: '/scope',
        release: (_) async {
          failedCalls++;
          throw StateError('native close failed');
        },
      ),
    );
    await expectLater(broken.retire(), throwsStateError);
    await expectLater(broken.retire(), throwsStateError);
    expect(failedCalls, 1);
  });
  test('progress error does not release scope until stream onDone', () async {
    final owner = ReceiveScopeOwner();
    var released = false;
    await owner.acquire(() async => IosReceiveScopeLease(leaseId: 'scope', path: '/scope', release: (_) async => released = true));
    final release = owner.retain();
    final events = StreamController<double>();
    final work = drainReceiveProgress(events.stream, (_) {}).whenComplete(release);
    final error = expectLater(work, throwsStateError);
    events.addError(StateError('request ended before worker drained'));
    final retired = owner.retire();
    await Future<void>.delayed(Duration.zero);
    expect(released, false);
    events.add(0.5);
    await events.close();
    await error;
    await retired;
    expect(released, true);
  });
  test('progress callback exceptions also drain rather than cancel native work', () async {
    final events = StreamController<double>();
    var cancelled = false;
    events.onCancel = () {
      cancelled = true;
    };
    final drained = drainReceiveProgress(events.stream, (_) => throw StateError('UI transport ended'));
    final error = expectLater(drained, throwsStateError);
    events.add(0.5);
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, false);
    await events.close();
    await error;
    expect(cancelled, true);
  });
}
