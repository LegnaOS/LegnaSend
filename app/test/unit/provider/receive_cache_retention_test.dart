import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict native policy parser and supported presets', () {
    expect(parseReceiveCacheRetentionPolicy('{"mode":"immediate","days":null}'), 0);
    expect(parseReceiveCacheRetentionPolicy('{"mode":"manual","days":null}'), -1);
    for (final days in [1, 7, 30, 3650]) {
      expect(parseReceiveCacheRetentionPolicy('{"mode":"days","days":$days}'), days);
    }
    for (final invalid in ['{}', '{"mode":"days","days":0}', '{"mode":"manual","days":1}', '{"mode":"days","days":3651}']) {
      expect(() => parseReceiveCacheRetentionPolicy(invalid), throwsFormatException);
    }
  });
  test('preferences default safely and persist all presets', () async {
    SharedPreferences.setMockInitialValues({'ls_security_context': '{}', 'ls_version': 999});
    final service = await PersistenceService.initialize(supportsDynamicColors: false);
    expect(service.getReceiveCacheRetentionDays(), 0);
    for (final days in receiveCacheRetentionChoices) {
      await service.setReceiveCacheRetentionDays(days);
      expect(service.getReceiveCacheRetentionDays(), days);
    }
    expect(() => service.setReceiveCacheRetentionDays(-2), throwsArgumentError);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('legnasend_receive_cache_retention_days', 'invalid');
    expect(service.getReceiveCacheRetentionDays(), -1);
    expect(service.hasInvalidReceiveCacheRetentionDays(), true);
    for (final corrupt in [-3, 3651]) {
      await prefs.setInt('legnasend_receive_cache_retention_days', corrupt);
      expect(service.getReceiveCacheRetentionDays(), -1);
    }
  });
  test('damaged saved policy retains files until explicit repair', () async {
    var invalid = true, saved = -1;
    final allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => saved,
      savedInvalid: () => invalid,
      save: (d) async {
        saved = d;
        invalid = false;
      },
      configure: (d) async => d,
      readActual: () async => -1,
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.initialize(), false);
    expect(controller.days, -1);
    expect(controller.error, 'invalid');
    expect(allowed.last, false);
    expect(await controller.change(7), true);
    expect(allowed.last, true);
    expect(invalid, false);
  });
  test('startup configures saved policy before permitting automatic cleanup', () async {
    var saved = 7, actual = 0;
    final allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => saved,
      save: (d) async => saved = d,
      configure: (d) async => actual = d,
      readActual: () async => actual,
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.initialize(), true);
    expect(allowed, [false, true]);
    expect(controller.days, 7);
    for (final days in receiveCacheRetentionChoices) {
      expect(await controller.change(days), true);
      expect(saved, days);
      expect(actual, days);
    }
  });
  test('apply failure rolls back preference and reports actual native policy', () async {
    var saved = 7;
    final allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => saved,
      save: (d) async => saved = d,
      configure: (_) async => throw StateError('bridge failed'),
      readActual: () async => 7,
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.change(30), false);
    expect(saved, 7);
    expect(controller.days, 7);
    expect(controller.error, 'apply');
    expect(allowed.last, true);
  });
  test('startup failure pauses cleanup even if getter matches saved policy', () async {
    final allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => 7,
      save: (_) async {},
      configure: (_) async => throw StateError('bridge failed'),
      readActual: () async => 7,
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.initialize(), false);
    expect(controller.ready, true);
    expect(allowed.last, false);
  });
  test('save failure never configures native; recovery failure keeps deletion paused', () async {
    final allowed = <bool>[];
    var calls = 0;
    final controller = ReceiveCacheRetentionController(
      readSaved: () => 7,
      save: (_) async => throw StateError('disk full'),
      configure: (d) async {
        calls++;
        return d;
      },
      readActual: () async => 7,
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.change(30), false);
    expect(controller.error, 'restore');
    expect(calls, 0);
    expect(allowed.last, false);
  });
  test('failed save with successful rollback reports save error', () async {
    var saved = 7, saves = 0;
    final controller = ReceiveCacheRetentionController(
      readSaved: () => saved,
      save: (d) async {
        if (++saves == 1) throw StateError('offline');
        saved = d;
      },
      configure: (d) async => d,
      readActual: () async => 7,
      allowAutomatic: (_) {},
    );
    addTearDown(controller.dispose);
    expect(await controller.change(1), false);
    expect(controller.error, 'save');
    expect(saved, 7);
  });
  test('unknown effective policy pauses automatic cleanup and allows retry', () async {
    var failing = true;
    final allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => -1,
      save: (_) async {},
      configure: (d) async {
        if (failing) throw StateError('offline');
        return d;
      },
      readActual: () async => throw StateError('offline'),
      allowAutomatic: allowed.add,
    );
    addTearDown(controller.dispose);
    expect(await controller.initialize(), false);
    expect(controller.ready, false);
    expect(allowed.last, false);
    failing = false;
    expect(await controller.initialize(), true);
    expect(controller.days, -1);
    expect(allowed.last, true);
  });
  test('single in-flight operation and disposal never reenable cleanup', () async {
    final pending = Completer<int>(), allowed = <bool>[];
    final controller = ReceiveCacheRetentionController(
      readSaved: () => 0,
      save: (_) async {},
      configure: (_) => pending.future,
      readActual: () async => 0,
      allowAutomatic: allowed.add,
    );
    final operation = controller.initialize();
    expect(await controller.change(7), false);
    controller.dispose();
    pending.complete(0);
    await operation;
    expect(allowed.last, false);
  });
}
