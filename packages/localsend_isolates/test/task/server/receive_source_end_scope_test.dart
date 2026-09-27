import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/receive_source_end_scope.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';

const _path = '/provider/中文 % files ';
IosReceiveScopeLease _lease({String path = _path, required Future<void> Function(String) release}) => IosReceiveScopeLease(
  leaseId: '19a3b3f0-141b-4c41-b421-2f68a0e929d3',
  path: path,
  release: release,
);

void main() {
  for (final supported in [false, true]) {
    test('unsupported or retired listener denies without acquiring (supported=$supported)', () async {
      final replies = <bool>[];
      final handler = ReceiveSourceEndScopeHandler(
        supported: supported,
        isCurrent: () => !supported,
        acquire: (_) => throw StateError('must not acquire'),
        reply: ({required requestId, required granted}) async {
          expect(requestId, 'old-request');
          replies.add(granted);
          return true;
        },
      );
      await handler.handle('old-request', _path);
      expect(replies, [false]);
    });
  }

  for (final code in ['receiveGrantBusy', 'receiveGrantUnavailable']) {
    test('$code denies without an ordinary-acquire or bare-path fallback', () async {
      var acquires = 0;
      final replies = <bool>[];
      final handler = ReceiveSourceEndScopeHandler(
        supported: true,
        isCurrent: () => true,
        acquire: (path) async {
          expect(path, _path);
          acquires++;
          throw PlatformException(code: code);
        },
        reply: ({required requestId, required granted}) async {
          replies.add(granted);
          return true;
        },
      );
      await handler.handle('request', _path);
      expect(acquires, 1);
      expect(replies, [false]);
    });
  }

  test('null and mismatched scopes never authorize external access', () async {
    var releases = 0;
    final replies = <bool>[];
    for (final mismatched in [false, true]) {
      await ReceiveSourceEndScopeHandler(
        supported: true,
        isCurrent: () => true,
        acquire: (_) async => mismatched
            ? _lease(
                path: '/other',
                release: (_) async {
                  releases++;
                },
              )
            : null,
        reply: ({required requestId, required granted}) async {
          replies.add(granted);
          return false;
        },
      ).handle('request', _path);
    }
    expect(replies, [false, false]);
    expect(releases, 1);
  });

  test('late acquisition denies original request and waits for denial before releasing', () async {
    final acquisition = Completer<IosReceiveScopeLease?>();
    final denial = Completer<bool>();
    final responded = Completer<void>();
    var current = true, releases = 0;
    final replies = <bool>[];
    final handling = ReceiveSourceEndScopeHandler(
      supported: true,
      isCurrent: () => current,
      acquire: (_) => acquisition.future,
      reply: ({required requestId, required granted}) {
        expect(requestId, 'original');
        replies.add(granted);
        responded.complete();
        return denial.future;
      },
    ).handle('original', _path);
    current = false;
    acquisition.complete(
      _lease(
        release: (_) async {
          releases++;
        },
      ),
    );
    await responded.future;
    expect(replies, [false]);
    expect(releases, 0);
    denial.complete(false);
    await handling;
    expect(releases, 1);
  });

  test('granted work survives stop until actual core drain and native release acknowledgement', () async {
    final core = Completer<bool>(), responded = Completer<void>(), releasing = Completer<void>(), release = Completer<void>();
    var current = true, finished = false, replies = 0;
    final handling = ReceiveSourceEndScopeHandler(
      supported: true,
      isCurrent: () => current,
      acquire: (_) async => _lease(
        release: (_) {
          releasing.complete();
          return release.future;
        },
      ),
      reply: ({required requestId, required granted}) {
        replies++;
        expect(granted, true);
        responded.complete();
        return core.future;
      },
    ).handle('request', _path).then((_) => finished = true);
    await responded.future;
    current = false;
    await Future<void>.delayed(Duration.zero);
    expect(releasing.isCompleted, false);
    expect(finished, false);
    core.complete(true);
    await releasing.future;
    expect(finished, false);
    release.complete();
    await handling;
    expect(replies, 1);
    expect(finished, true);
  });

  test('core terminal error releases once and does not send a second decision', () async {
    var releases = 0, replies = 0;
    final handler = ReceiveSourceEndScopeHandler(
      supported: true,
      isCurrent: () => true,
      acquire: (_) async => _lease(
        release: (_) async {
          releases++;
        },
      ),
      reply: ({required requestId, required granted}) async {
        replies++;
        throw StateError('worker terminated');
      },
    );
    await expectLater(handler.handle('request', _path), throwsStateError);
    expect(releases, 1);
    expect(replies, 1);
  });

  test('stale core rejection and release error remain observable', () async {
    var releases = 0;
    final handler = ReceiveSourceEndScopeHandler(
      supported: true,
      isCurrent: () => true,
      acquire: (_) async => _lease(
        release: (_) async {
          releases++;
          throw StateError('release unacknowledged');
        },
      ),
      reply: ({required requestId, required granted}) async => false,
    );
    await expectLater(handler.handle('request', _path), throwsStateError);
    expect(releases, 1);
  });

  test('unawaited scope worker does not stall another listener event', () async {
    final core = Completer<bool>(), responded = Completer<void>();
    final events = StreamController<String>();
    final observed = <String>[];
    Future<void>? scope;
    var releases = 0;
    final handler = ReceiveSourceEndScopeHandler(
      supported: true,
      isCurrent: () => true,
      acquire: (_) async => _lease(
        release: (_) async {
          releases++;
        },
      ),
      reply: ({required requestId, required granted}) {
        responded.complete();
        return core.future;
      },
    );
    final listening = (() async {
      await for (final event in events.stream) {
        if (event == 'scope') {
          unawaited(scope = handler.handle('request', _path));
        } else {
          observed.add(event);
        }
      }
    })();
    events.add('scope');
    await responded.future;
    events.add('next-upload');
    await events.close();
    await listening;
    expect(observed, ['next-upload']);
    expect(releases, 0);
    core.complete(true);
    await scope;
    expect(releases, 1);
  });
}
