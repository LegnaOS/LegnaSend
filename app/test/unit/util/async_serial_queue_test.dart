import 'dart:async';

import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:test/test.dart';

void main() {
  test('restart finishes before a later stop starts', () async {
    final queue = AsyncSerialQueue();
    final gate = Completer<void>();
    final events = <String>[];
    final restart = queue.run(() async {
      events.add('stop old');
      await gate.future;
      events.add('start new');
    });
    final stop = queue.run(() async => events.add('stop new'));
    await Future<void>.delayed(Duration.zero);
    expect(events, ['stop old']);
    gate.complete();
    await Future.wait([restart, stop]);
    expect(events, ['stop old', 'start new', 'stop new']);
  });

  test('failed start does not block restoring the server', () async {
    final queue = AsyncSerialQueue();
    final failure = queue.run<void>(() async => throw StateError('bind failed'));
    final recovery = queue.run(() async => 'restored');
    await expectLater(failure, throwsStateError);
    expect(await recovery, 'restored');
  });
}
