import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/util/upload_scheduler.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('5000 small files use six lanes, exactly once and in input order', () async {
    final started = <int>[];
    var active = 0;
    var peak = 0;
    await UploadScheduler().run<int>(
      List.generate(5000, (i) => i),
      sizeOf: (_) => 1024,
      isCancelled: () => false,
      upload: (i) async {
        started.add(i);
        active++;
        if (active > peak) peak = active;
        await tick();
        active--;
      },
    );
    expect(started, List.generate(5000, (i) => i));
    expect(peak, 6);
    expect(active, 0);
  });

  test('large files retain two lanes, including unknown sizes', () async {
    for (final size in [UploadScheduler.smallFileLimit + 1, -1]) {
      var active = 0;
      var peak = 0;
      await UploadScheduler().run<int>(
        List.generate(20, (i) => i),
        sizeOf: (_) => size,
        isCancelled: () => false,
        upload: (_) async {
          if (++active > peak) peak = active;
          await tick();
          active--;
        },
      );
      expect(peak, 2);
    }
  });

  test('zero and threshold-sized files use small lanes', () async {
    for (final size in [0, UploadScheduler.smallFileLimit]) {
      final gate = Completer<void>();
      var started = 0;
      final task = UploadScheduler().run<int>(
        List.filled(10, size),
        sizeOf: (size) => size,
        isCancelled: () => false,
        upload: (_) async {
          started++;
          await gate.future;
        },
      );
      await tick();
      expect(started, 6);
      gate.complete();
      await task;
      expect(started, 10);
    }
  });

  test('mixed tasks reserve two large lanes and four small lanes without head-of-line blocking', () async {
    final largeGate = Completer<void>();
    var activeLarge = 0;
    var peakLarge = 0;
    final smallDone = <int>[];
    final task = UploadScheduler().run<int>(
      List.generate(40, (i) => i),
      sizeOf: (i) => i < 20 ? 1024 * 1024 : 1024,
      isCancelled: () => false,
      upload: (i) async {
        if (i < 20) {
          if (++activeLarge > peakLarge) peakLarge = activeLarge;
          await largeGate.future;
          activeLarge--;
        } else {
          smallDone.add(i);
          await tick();
        }
      },
    );
    for (var i = 0; i < 10; i++) {
      await tick();
    }
    expect(peakLarge, 2);
    expect(smallDone, List.generate(20, (i) => i + 20));
    largeGate.complete();
    await task;
    expect(activeLarge, 0);
  });

  test('all tasks share eight permits and waiting peers get a turn', () async {
    final scheduler = UploadScheduler();
    final gate = Completer<void>();
    final starts = <int>[];
    var active = 0;
    var peak = 0;
    Future<void> run(int taskId) => scheduler.run<int>(
      List.generate(40, (i) => i),
      sizeOf: (_) => 1,
      isCancelled: () => false,
      upload: (_) async {
        starts.add(taskId);
        if (++active > peak) peak = active;
        await gate.future;
        await tick();
        active--;
      },
    );
    final tasks = [run(0), run(1), run(2)];
    await tick();
    expect(starts, [0, 0, 0, 0, 0, 0, 1, 1]);
    gate.complete();
    await Future.wait(tasks);
    expect(peak, 8);
    expect(starts.take(18).toSet(), {0, 1, 2});
    expect(starts.length, 120);
  });

  test('cancel before start and empty lists do not invoke upload', () async {
    final scheduler = UploadScheduler();
    for (final files in [
      <int>[],
      [1, 2, 3],
    ]) {
      await scheduler.run<int>(files, sizeOf: (_) => 0, isCancelled: () => true, upload: (_) async => fail('unexpected upload'));
    }
    await scheduler.run<int>([], sizeOf: (_) => 0, isCancelled: () => false, upload: (_) async => fail('unexpected upload'));
  });

  test('cancel drains active work and does not start queued files', () async {
    final gate = Completer<void>();
    var cancelled = false;
    var started = 0;
    var finished = false;
    final task = UploadScheduler()
        .run<int>(
          List.filled(5000, 1),
          sizeOf: (_) => 1,
          isCancelled: () => cancelled,
          upload: (_) async {
            started++;
            await gate.future;
          },
        )
        .then((_) => finished = true);
    await tick();
    cancelled = true;
    await tick();
    expect(started, 6);
    expect(finished, false);
    gate.complete();
    await task;
    expect(started, 6);
  });

  test('cancel while waiting for global permit never starts a file', () async {
    final scheduler = UploadScheduler();
    final gate = Completer<void>();
    var cancelled = false;
    Future<void> occupy() => scheduler.run<int>(List.filled(6, 1), sizeOf: (_) => 1, isCancelled: () => false, upload: (_) => gate.future);
    final running = [occupy(), occupy()];
    await tick();
    final waiting = scheduler.run<int>(
      List.filled(6, 1),
      sizeOf: (_) => 1,
      isCancelled: () => cancelled,
      upload: (_) async => fail('cancelled file started'),
    );
    cancelled = true;
    gate.complete();
    await Future.wait([...running, waiting]);
  });

  test('unexpected error drains siblings, stops queue, releases permits and preserves error', () async {
    final scheduler = UploadScheduler();
    final gate = Completer<void>();
    final error = StateError('source failure');
    var started = 0;
    var settled = false;
    final task = scheduler.run<int>(
      List.generate(100, (i) => i),
      sizeOf: (_) => 1,
      isCancelled: () => false,
      upload: (i) async {
        started++;
        if (i == 0) throw error;
        await gate.future;
      },
    );
    final check = expectLater(task.whenComplete(() => settled = true), throwsA(same(error)));
    await tick();
    expect(started, 6);
    expect(settled, false);
    gate.complete();
    await check;
    var next = 0;
    await scheduler.run<int>(
      List.filled(100, 1),
      sizeOf: (_) => 1,
      isCancelled: () => false,
      upload: (_) async {
        next++;
      },
    );
    expect(next, 100);
  });

  test('handled per-file failures and retries keep their permit and allow following files', () async {
    final attempts = <int, int>{};
    final done = <int>[];
    await UploadScheduler().run<int>(
      List.generate(50, (i) => i),
      sizeOf: (_) => 1,
      isCancelled: () => false,
      upload: (i) async {
        for (var attempt = 1; attempt <= 3; attempt++) {
          attempts[i] = attempt;
          await tick();
          if (i != 3 && i != 4) {
            done.add(i);
            break;
          }
        }
      },
    );
    expect(attempts.length, 50);
    expect(attempts[3], 3);
    expect(attempts[4], 3);
    expect(done.length, 48);
  });
}
