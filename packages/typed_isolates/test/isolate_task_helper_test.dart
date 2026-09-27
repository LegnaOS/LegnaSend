import 'dart:async';
import 'dart:isolate';

import 'package:typed_isolates/src/isolate_helper.dart';
import 'package:typed_isolates/src/isolate_task.dart';
import 'package:typed_isolates/src/isolate_task_helper.dart';
import 'package:typed_isolates/src/isolate_task_result.dart';

// Standalone host regression suite; this package intentionally has no test-runner
// dependency. Execute with `fvm dart run test/isolate_task_helper_test.dart`.
void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class _Connector implements IsolateConnector<IsolateTaskStreamResult<String>, IsolateTask<String>> {
  final StreamController<IsolateTaskStreamResult<String>> source = StreamController.broadcast(sync: true);
  final List<IsolateTask<String>> sent = [];
  @override
  Stream<IsolateTaskStreamResult<String>> get receiveFromIsolate => source.stream;
  @override
  Isolate get isolate => Isolate.current;
  @override
  void sendToIsolate(IsolateTask<String> message) {
    sent.add(message);
    source.add(IsolateTaskStreamResult.event(id: message.id, data: message.data));
    source.add(IsolateTaskStreamResult.done(id: message.id));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  var cases = 0;
  Future<void> run(Future<void> Function(_Connector) body) async {
    final connector = _Connector();
    try {
      await body(connector).timeout(const Duration(seconds: 2));
      check(!connector.source.hasListener, 'Terminal task retained its upstream subscription');
      cases++;
    } finally {
      await connector.source.close();
    }
  }

  await run((connector) async {
    final values = connector.convertResponseToStream(taskId: 7).toList();
    connector.source.add(IsolateTaskStreamResult.event(id: 8, data: 'unrelated'));
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'first'));
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'second'));
    connector.source.add(IsolateTaskStreamResult.done(id: 7));
    check((await values).join(',') == 'first,second', 'Task ID or event ordering changed');
  });
  await run((connector) async {
    Object? failure;
    final done = Completer<void>();
    final values = <String>[];
    connector.convertResponseToStream(taskId: 7).listen(values.add, onError: (Object error) {
      failure = error;
    }, onDone: done.complete);
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'before-error'));
    connector.source.add(IsolateTaskStreamResult.error(id: 7, error: 'late management receipt'));
    await done.future;
    check(failure == 'late management receipt' && values.single == 'before-error', 'Error should follow prior events and then close');
  });
  await run((connector) async {
    final first = connector.convertResponseToStream(taskId: 7).first;
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'receipt'));
    check(await first == 'receipt', 'First response was lost');
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'late'));
    connector.source.add(IsolateTaskStreamResult.error(id: 7, error: 'ignored after consumer cancellation'));
  });
  await run((connector) async {
    final subscription = connector.convertResponseToStream(taskId: 7).listen((_) {
      throw StateError('Unexpected reply');
    });
    await subscription.cancel();
    connector.source.add(IsolateTaskStreamResult.error(id: 7, error: 'after cancellation'));
  });
  await run((connector) async {
    final stream = connector.convertResponseToStream(taskId: 7);
    connector.source.add(IsolateTaskStreamResult.event(id: 7, data: 'already arrived'));
    connector.source.add(IsolateTaskStreamResult.done(id: 7));
    check((await stream.toList()).single == 'already arrived', 'A reply before downstream listen must remain buffered');
  });
  await run((connector) async {
    final first = connector.sendTaskAndListenStream(task: 'immediate echo', taskId: 41).first;
    check(await first == 'immediate echo', 'Scheduled send raced its response subscription');
    check(connector.sent.single.id == 41, 'Task identity changed');
  });
  await run((connector) async {
    Object? failure;
    final done = Completer<void>();
    connector.convertResponseToStream(taskId: 7).listen((_) {}, onError: (Object error) {
      failure = error;
    }, onDone: done.complete);
    connector.source.addError(StateError('Upstream failed'));
    await done.future;
    check(failure is StateError, 'Upstream error was not forwarded');
  });
  await run((connector) async {
    final result = connector.convertResponseToStream(taskId: 7).toList();
    await connector.source.close();
    check((await result).isEmpty, 'Upstream close did not finish the task stream');
  });
  await run((connector) async {
    for (var i = 0; i < 100; i++) {
      final completed = Completer<void>();
      connector.convertResponseToStream(taskId: i).listen((_) {}, onError: (Object _) {}, onDone: completed.complete);
      connector.source.add(IsolateTaskStreamResult.error(id: i, error: 'expired receipt'));
      await completed.future;
      check(!connector.source.hasListener, 'Repeated terminal errors accumulated listeners at $i');
    }
  });
  print('Typed isolate task stream cleanup: $cases cases passed');
}
