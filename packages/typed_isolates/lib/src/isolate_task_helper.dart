import 'dart:async';

import 'package:typed_isolates/src/id_provider.dart';
import 'package:typed_isolates/src/isolate_helper.dart';
import 'package:typed_isolates/src/isolate_task.dart';
import 'package:typed_isolates/src/isolate_task_result.dart';

/// Helpers for connectors whose child isolate replies with
/// [IsolateTaskStreamResult]s (the request / streamed-response pattern).
extension IsolateTaskStreamConnector<R, S> on IsolateConnector<IsolateTaskStreamResult<R>, S> {
  /// Listens to the responses of an already-sent task with [taskId] and
  /// transforms the [IsolateTaskStreamResult]s into a plain [Stream].
  Stream<R> convertResponseToStream({
    required int taskId,
  }) {
    StreamSubscription<IsolateTaskStreamResult<R>>? subscription;
    var ended = false;
    final controller = StreamController<R>(
      onCancel: () async {
        ended = true;
        await subscription?.cancel();
      },
    );
    void finish() {
      if (ended) return;
      ended = true;
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    // Subscribe before returning or scheduling a task. An immediate child reply
    // must be buffered even when the caller has not listened to this stream yet.
    subscription = receiveFromIsolate.listen(
      (result) {
        if (ended || result.id != taskId) return;
        if (result.data != null) {
          controller.add(result.data as R);
        } else if (result.done) {
          if (result.error != null) controller.addError(result.error!);
          // Terminal errors own the same cleanup as successful completion.
          finish();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (ended) return;
        controller.addError(error, stack);
        finish();
      },
      onDone: finish,
    );
    // Also handles a custom synchronous stream ending during listen().
    if (ended) unawaited(subscription.cancel());

    return controller.stream;
  }
}

/// Helpers for connectors that send bare [IsolateTask]s (no envelope).
extension IsolateTaskConnector<R, T> on IsolateConnector<IsolateTaskStreamResult<R>, IsolateTask<T>> {
  /// Sends a [task] to the isolate and transforms the responded
  /// [IsolateTaskStreamResult]s into a plain [Stream].
  ///
  /// The [task] is wrapped in an [IsolateTask] with a unique id (taken from
  /// [IdProvider.instance], or [taskId] if provided).
  ///
  /// If the connector sends a custom envelope instead of a bare [IsolateTask],
  /// wrap and send the task yourself and use [convertResponseToStream].
  Stream<R> sendTaskAndListenStream({
    required T task,
    int? taskId,
  }) {
    final isolateTask = IsolateTask(
      id: taskId ?? IdProvider.instance.getNextId(),
      data: task,
    );

    // ignore: discarded_futures
    Future.microtask(() {
      sendToIsolate(isolateTask);
    });

    return convertResponseToStream(taskId: isolateTask.id);
  }
}
