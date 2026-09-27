import 'dart:math' as math;

import 'package:pool/pool.dart';

/// A shared budget for native upload tasks, independent of isolate messaging.
/// No file/descriptor is opened until [upload] runs inside a permit. Keep one
/// scheduler per upload isolate, not one per task or peer.
class UploadScheduler {
  static const smallFileLimit = 256 * 1024;
  static const taskConcurrency = 6;
  static const largeFileConcurrency = 2;
  static const globalConcurrency = 8;

  final Pool _permits = Pool(globalConcurrency);

  /// Small files do not wait behind a large-file tail. Each group preserves
  /// input order, while completion order remains independent, as in v2.
  /// Only a bounded number of workers/futures exist, regardless of list size.
  /// A caller handles recoverable per-file failures inside [upload]; an
  /// unexpected exception stops dequeuing, drains active work, then rethrows.
  Future<void> run<T>(
    List<T> files, {
    required int Function(T file) sizeOf,
    required bool Function() isCancelled,
    required Future<void> Function(T file) upload,
  }) async {
    if (files.isEmpty || isCancelled()) return;
    bool small(T file) => sizeOf(file) >= 0 && sizeOf(file) <= smallFileLimit;
    final smallCount = files.where(small).length;
    final largeCount = files.length - smallCount;
    final largeWorkers = math.min(largeFileConcurrency, largeCount);
    final smallWorkers = math.min(taskConcurrency - largeWorkers, smallCount);
    final smallFiles = files.where(small).iterator;
    final largeFiles = files.where((file) => !small(file)).iterator;
    (Object, StackTrace)? failure;

    Future<void> worker(Iterator<T> iterator) async {
      while (!isCancelled() && failure == null) {
        // The cursor is advanced only while holding a permit. Cancellation
        // while waiting never announces/opens a file or consumes its token.
        final progressed = await _permits.withResource(() async {
          if (isCancelled() || failure != null || !iterator.moveNext()) return false;
          final file = iterator.current;
          try {
            await upload(file);
          } catch (error, stack) {
            failure ??= (error, stack);
          }
          return true;
        });
        if (!progressed) return;
      }
    }

    await Future.wait([
      for (var i = 0; i < smallWorkers; i++) worker(smallFiles),
      for (var i = 0; i < largeWorkers; i++) worker(largeFiles),
    ]);
    if (failure case (final error, final stack)) Error.throwWithStackTrace(error, stack);
  }
}
