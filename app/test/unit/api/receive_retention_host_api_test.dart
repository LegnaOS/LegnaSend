import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:localsend_app/util/api/host_management.dart';

class _Fixture {
  int saved = 7, actual = 7, actualReads = 0, claims = 0, writes = 0;
  bool invalidSaved = false;
  final saves = <int>[], applies = <int>[], automatic = <bool>[], cacheCalls = <bool>[];
  Future<void> Function(int)? saveHook;
  Future<int> Function(int)? applyHook;
  Future<int> Function()? actualHook;
  late final controller = ReceiveCacheRetentionController(
    readSaved: () => saved,
    savedInvalid: () => invalidSaved,
    save: (days) async {
      saves.add(days);
      await saveHook?.call(days);
      saved = days;
    },
    configure: (days) async {
      applies.add(days);
      if (applyHook != null) return applyHook!(days);
      return actual = days;
    },
    readActual: () async {
      actualReads++;
      return actualHook == null ? actual : await actualHook!();
    },
    allowAutomatic: automatic.add,
  );
  late final host = HostManagement(
    readSettings: () => {'alias': 'Legna', 'receiveCacheRetentionDays': saved},
    receiveCacheRetention: () => controller.snapshot(),
    writeSetting: (field, value) async {
      writes++;
      expect(field, 'receiveCacheRetentionDays');
      if (controller.busy) throw const HostSettingsBusy();
      if (!await controller.change(value as int)) throw StateError('private storage /private/retention');
    },
    cache: (cleanup) async {
      cacheCalls.add(cleanup);
      return {'examined': 0};
    },
  );
  Future<Map<String, dynamic>> call(String operation, {Map<String, Object?>? change, Future<bool> Function()? claim}) async =>
      jsonDecode(
            await host.execute(
              request: jsonEncode({
                'operation': 'host.$operation',
                'principal': 'key',
                'workspaces': ['*'],
                'change': ?change,
              }),
              claim:
                  claim ??
                  () async {
                    claims++;
                    return true;
                  },
            ),
          )
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> read() async {
    final result = await call('settings.read');
    expect(result['status'], 200);
    return result['body'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> change(Object? value, {String? version, Future<bool> Function()? claim}) async => call(
    'settings.update',
    change: {'version': version ?? (await read())['version'], 'field': 'receiveCacheRetentionDays', 'value': value},
    claim: claim,
  );
  void dispose() => controller.dispose();
}

void expectState(Map<String, dynamic> body, {required int saved, required int? effective, required bool paused, bool busy = false, String? error}) {
  expect(body['settings']['receiveCacheRetentionDays'], saved);
  expect(body['receiveCacheRetention'], {
    'effectiveDays': effective,
    'automaticCleanupPaused': paused,
    'busy': busy,
    'error': error,
  });
  expect(body['version'], matches(RegExp(r'^[a-f0-9]{64}$')));
}

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.dispose());

  test('saved preference is never presented as effective policy before initialization', () async {
    final body = await fixture.read();
    expectState(body, saved: 7, effective: null, paused: true);
    expect(fixture.controller.automaticCleanupAllowed, false);
    expect(fixture.saves, isEmpty);
    expect(fixture.applies, isEmpty);
    expect(fixture.actualReads, 0);
    expect(fixture.cacheCalls, isEmpty);
  });

  test('successful typed retention updates expose actual policy without triggering cleanup', () async {
    expect(await fixture.controller.initialize(), true);
    for (final days in [-1, 0, 1, 7, 30, 3650]) {
      final old = (await fixture.read())['version'];
      final result = await fixture.change(days);
      expect(result['status'], 200);
      expectState(result['body'], saved: days, effective: days, paused: false);
      expect(fixture.actual, days);
      expect(result['body']['version'], isNot(old));
      expect(fixture.controller.automaticCleanupAllowed, true);
    }
    expect(fixture.saves, [-1, 0, 1, 7, 30, 3650]);
    expect(fixture.applies, [7, -1, 0, 1, 7, 30, 3650]);
    expect(fixture.cacheCalls, isEmpty);
  });

  test('out-of-range integers, booleans, doubles and strings are rejected before claim or apply', () async {
    await fixture.controller.initialize();
    final version = (await fixture.read())['version'] as String;
    final oldClaims = fixture.claims;
    for (final value in <Object>[-2, 3651, true, false, 1.0, -1.0, '7', 'manual']) {
      final result = await fixture.change(value, version: version);
      expect(result['status'], 400, reason: '$value (${value.runtimeType})');
      expect(result['body']['error']['code'], 'invalid_setting');
    }
    expect(fixture.claims, oldClaims);
    expect(fixture.writes, 0);
    expect(fixture.saves, isEmpty);
    expect(fixture.applies, [7]);
  });

  test('version tracks busy and effective state even while saved settings stay unchanged', () async {
    final before = await fixture.read();
    final gate = Completer<int>();
    fixture.applyHook = (_) => gate.future;
    final initializing = fixture.controller.initialize();
    final during = await fixture.read();
    expectState(during, saved: 7, effective: null, paused: true, busy: true);
    expect(during['settings'], before['settings']);
    expect(during['version'], isNot(before['version']));
    gate.complete(7);
    expect(await initializing, true);
    final after = await fixture.read();
    expectState(after, saved: 7, effective: 7, paused: false);
    expect(after['settings'], before['settings']);
    expect(after['version'], isNot(during['version']));
    expect((await fixture.read())['version'], after['version']);
  });

  test('error and paused changes invalidate versions without changing saved or actual days', () async {
    await fixture.controller.initialize();
    final before = await fixture.read();
    fixture.applyHook = (_) async => throw StateError('native unavailable');
    expect(await fixture.controller.initialize(), false);
    final after = await fixture.read();
    expectState(after, saved: 7, effective: 7, paused: true, error: 'apply');
    expect(after['settings'], before['settings']);
    expect(after['version'], isNot(before['version']));
    expect(fixture.actualReads, 1);
  });

  test('apply failure returns 503 then read reports actual policy rather than rolled-back preference', () async {
    await fixture.controller.initialize();
    fixture.applyHook = (days) async {
      fixture.actual = days;
      throw StateError('/private/native acknowledgement lost');
    };
    final result = await fixture.change(30);
    expect(result['status'], 503);
    expect(result['body'], {
      'error': {'code': 'host_operation_failed'},
    });
    expect(jsonEncode(result), isNot(contains('/private')));
    expect(fixture.saves, [30, 7]);
    expect(fixture.actualReads, 1);
    expectState(await fixture.read(), saved: 7, effective: 30, paused: true, error: 'apply');
  });

  test('save failure does not apply, and read distinguishes save error after successful rollback', () async {
    await fixture.controller.initialize();
    fixture.saveHook = (days) async {
      if (days == 30) throw StateError('/private/disk full');
    };
    final result = await fixture.change(30);
    expect(result['status'], 503);
    expect(result['body']['error']['code'], 'host_operation_failed');
    expect(fixture.applies, [7]);
    expect(fixture.saves, [30, 7]);
    expectState(await fixture.read(), saved: 7, effective: 7, paused: false, error: 'save');
  });

  test('failed restore keeps automatic cleanup paused and exposes persistence uncertainty', () async {
    await fixture.controller.initialize();
    fixture.applyHook = (_) async => throw StateError('apply failed');
    fixture.saveHook = (days) async {
      if (days == 7) throw StateError('rollback failed');
    };
    expect((await fixture.change(30))['status'], 503);
    expectState(await fixture.read(), saved: 30, effective: 7, paused: true, error: 'restore');
  });

  test('failed runtime read exposes unknown actual policy instead of a stale day value', () async {
    await fixture.controller.initialize();
    fixture.applyHook = (_) async => throw StateError('configure unavailable');
    fixture.actualHook = () async => throw StateError('read unavailable');
    expect((await fixture.change(30))['status'], 503);
    expectState(await fixture.read(), saved: 7, effective: null, paused: true, error: 'apply');
  });

  test('invalid saved policy remains explicit until an API repair succeeds', () async {
    fixture.saved = -1;
    fixture.invalidSaved = true;
    expect(await fixture.controller.initialize(), false);
    expectState(await fixture.read(), saved: -1, effective: -1, paused: true, error: 'invalid');
    fixture.saveHook = (_) async => fixture.invalidSaved = false;
    final result = await fixture.change(7);
    expect(result['status'], 200);
    expectState(result['body'], saved: 7, effective: 7, paused: false);
  });

  test('a locally busy retention controller rejects API mutation without any extra save or apply', () async {
    final gate = Completer<int>();
    fixture.applyHook = (_) => gate.future;
    final local = fixture.controller.initialize();
    final busyVersion = (await fixture.read())['version'] as String;
    final result = await fixture.change(30, version: busyVersion);
    expect(result['status'], 409);
    expect(result['body'], {
      'error': {'code': 'settings_busy'},
    });
    expect(fixture.saves, isEmpty);
    expect(fixture.applies, [7]);
    expect(fixture.controller.busy, true);
    gate.complete(7);
    expect(await local, true);
  });

  test('effective-state changes while awaiting claim reject the stale request before write', () async {
    await fixture.controller.initialize();
    final old = (await fixture.read())['version'] as String;
    final gate = Completer<bool>(), entered = Completer<void>(), localGate = Completer<int>();
    final pending = fixture.change(
      30,
      version: old,
      claim: () {
        entered.complete();
        return gate.future;
      },
    );
    await entered.future;
    fixture.applyHook = (_) => localGate.future;
    final local = fixture.controller.initialize();
    expect(fixture.saved, 7);
    expect(fixture.controller.busy, true);
    gate.complete(true);
    final result = await pending;
    expect(result['status'], 409);
    expect(result['body']['error']['code'], 'settings_changed');
    expect(fixture.writes, 0);
    expect(fixture.saves, isEmpty);
    expect(fixture.applies, [7, 7]);
    localGate.complete(7);
    await local;
  });

  test('cache response envelopes stay unchanged and inspection does not apply retention', () async {
    final before = fixture.controller.snapshot();
    expect(await fixture.call('cache.inspect'), {
      'status': 200,
      'body': {'examined': 0},
    });
    expect(fixture.controller.snapshot(), before);
    expect(fixture.applies, isEmpty);
    expect(fixture.saves, isEmpty);
    expect(fixture.cacheCalls, [false]);
  });
  test('mismatched acknowledgement recovers actual policy and gates mismatch', () async {
    await fixture.controller.initialize();
    fixture.applyHook = (days) async {
      fixture.actual = days;
      return 0;
    };
    final result = await fixture.change(30);
    expect(result['status'], 503);
    expectState(await fixture.read(), saved: 7, effective: 30, paused: true, error: 'apply');
    expect(fixture.automatic.last, false);
    expect(fixture.controller.automaticCleanupAllowed, fixture.automatic.last);
  });
  test('invalid recovered runtime value stays unknown and paused', () async {
    await fixture.controller.initialize();
    fixture.applyHook = (_) async => throw StateError('bad acknowledgment');
    fixture.actualHook = () async => -2;
    final result = await fixture.change(30);
    expect(result['status'], 503);
    expectState(await fixture.read(), saved: 7, effective: null, paused: true, error: 'apply');
    expect(fixture.controller.automaticCleanupAllowed, fixture.automatic.last);
  });
}
