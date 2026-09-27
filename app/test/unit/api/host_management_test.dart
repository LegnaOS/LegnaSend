import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/api/host_management.dart';

void main() {
  late Map<String, Object> settings;
  late HostManagement manager;
  late List<(String, Object)> writes;
  late List<bool> cacheCalls;
  late bool failWrite;
  Future<Map<String, dynamic>> call(
    String operation, {
    Map<String, Object>? change,
    Future<bool> Function()? claim,
    List<String> workspaces = const ['*'],
    String? principal = 'key',
  }) async =>
      jsonDecode(
            await manager.execute(
              request: jsonEncode({
                'operation': 'host.$operation',
                'principal': principal,
                'workspaces': workspaces,
                'change': ?change,
              }),
              claim: claim ?? () async => true,
            ),
          )
          as Map<String, dynamic>;
  Future<String> version() async => (await call('settings.read'))['body']['version'] as String;
  setUp(() {
    settings = {
      'alias': 'Legna',
      'theme': 'system',
      'locale': 'system',
      'enableAnimations': true,
      'autoFinish': false,
      'createChecksums': true,
      'verifyChecksums': true,
    };
    writes = [];
    cacheCalls = [];
    failWrite = false;
    manager = HostManagement(
      readSettings: () => Map.of(settings),
      writeSetting: (field, value) async {
        if (failWrite) throw StateError('private path');
        writes.add((field, value));
        settings[field] = value;
      },
      cache: (clean) async {
        cacheCalls.add(clean);
        return {'examined': 1};
      },
    );
  });
  test('read is a versioned non-secret allowlist; no persistence snapshot escapes', () async {
    final response = await call('settings.read');
    expect(response['status'], 200);
    expect(response['body']['version'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(response['body']['settings'], settings);
    expect((await version()), response['body']['version']);
    expect(writes, isEmpty);
  });
  test('supported setting update returns only after persistence and changes version', () async {
    final old = await version();
    final result = await call('settings.update', change: {'version': old, 'field': 'theme', 'value': 'dark'});
    expect(result['status'], 200);
    expect(writes, [('theme', 'dark')]);
    expect(result['body']['version'], isNot(old));
  });
  test('changed settings while waiting to claim prevent stale writes', () async {
    final gate = Completer<bool>();
    final old = await version();
    final future = call('settings.update', change: {'version': old, 'field': 'alias', 'value': 'new'}, claim: () => gate.future);
    await Future<void>.delayed(Duration.zero);
    settings['alias'] = 'local change';
    gate.complete(true);
    expect((await future)['body']['error']['code'], 'settings_changed');
    expect(writes, isEmpty);
  });
  test('unknown fields, wrong value types and invalid themes do not write', () async {
    for (final change in [
      {'field': 'destination', 'value': '/private'},
      {'field': 'verifyChecksums', 'value': 'true'},
      {'field': 'theme', 'value': 'pink'},
      {'field': 'alias', 'value': '  '},
    ]) {
      expect((await call('settings.update', change: {'version': await version(), ...change}))['status'], 400);
    }
    expect(writes, isEmpty);
  });
  test('expired claim prevents writes and cleanup; errors never echo source paths', () async {
    expect((await call('cache.cleanup', claim: () async => false))['status'], 409);
    expect(cacheCalls, isEmpty);
    failWrite = true;
    final result = await call('settings.update', change: {'version': await version(), 'field': 'alias', 'value': 'new'});
    expect(result['status'], 503);
    expect(jsonEncode(result), isNot(contains('private path')));
  });
  test('cache inspection and cleanup are explicit independent operations', () async {
    await call('cache.inspect');
    await call('cache.cleanup');
    expect(cacheCalls, [false, true]);
    expect(writes, isEmpty);
  });
  test('global operations reject anonymous and restricted grants', () async {
    expect((await call('cache.cleanup', principal: null))['status'], 403);
    expect((await call('settings.read', workspaces: ['workspace']))['status'], 403);
    expect(cacheCalls, isEmpty);
    for (final scope in [ApiScope.cacheRead, ApiScope.cacheClean, ApiScope.settingsRead, ApiScope.settingsWrite]) {
      expect(scope.requiresGlobal, true);
      expect(scope.allowsAnonymous, false);
    }
  });
  test('explorer validates typed body and requests page confirmation for cleanup and settings', () {
    final catalog = ApiCatalog.parse(File('assets/api_docs/integration-openapi-en.json').readAsStringSync());
    final update = catalog.operations.singleWhere((op) => op.id == 'updateSettings');
    final values = {'body.version': 'a' * 64, 'body.field': 'verifyChecksums', 'body.value': 'false'};
    expect(update.valid(values), true);
    expect(update.body(values)!['value'], false);
    expect(update.isMutation, true);
    expect(update.valid({...values, 'body.value': 'maybe'}), false);
    expect(update.valid({...values, 'body.version': 'bad'}), false);
    expect(catalog.operations.singleWhere((op) => op.id == 'cleanupCache').isMutation, true);
    for (final example in update.examples(Uri.parse('http://127.0.0.1:53317'), values).values) {
      expect(example, contains('SETTINGS_VERSION'));
      expect(example, contains('false'));
    }
  });
  test('pending restart changes the version without changing persisted settings or triggering writes', () async {
    var pending = <String>[];
    manager = HostManagement(
      readSettings: () => Map.of(settings),
      pendingRestart: () => List.of(pending),
      writeSetting: (field, value) async => writes.add((field, value)),
      cache: (clean) async {
        cacheCalls.add(clean);
        return {'examined': 0};
      },
    );
    final first = await call('settings.read');
    final originalSettings = Map.of(settings);
    expect(first['body']['pendingRestart'], isEmpty);
    pending = ['alias'];
    final next = await call('settings.read');
    expect(next['body']['settings'], originalSettings);
    expect(next['body']['pendingRestart'], ['alias']);
    expect(next['body']['version'], isNot(first['body']['version']));
    final stale = await call(
      'settings.update',
      change: {
        'version': first['body']['version'] as String,
        'field': 'theme',
        'value': 'dark',
      },
    );
    expect(stale['status'], 409);
    expect(stale['body']['error']['code'], 'settings_changed');
    expect(writes, isEmpty);
    expect(cacheCalls, isEmpty);
  });

  test('saved alias and verification updates expose pending restart and never apply listener state', () async {
    var listenerAlias = 'Legna';
    var listenerVerification = true;
    manager = HostManagement(
      readSettings: () => Map.of(settings),
      pendingRestart: () => [
        if (settings['alias'] != listenerAlias) 'alias',
        if (settings['verifyChecksums'] != listenerVerification) 'verifyChecksums',
      ],
      writeSetting: (field, value) async {
        writes.add((field, value));
        settings[field] = value;
      },
      cache: (clean) async {
        cacheCalls.add(clean);
        return {'examined': 0};
      },
    );
    final alias = await call('settings.update', change: {'version': await version(), 'field': 'alias', 'value': 'Saved name'});
    expect(alias['status'], 200);
    expect(alias['body']['pendingRestart'], ['alias']);
    expect(listenerAlias, 'Legna');
    final verification = await call('settings.update', change: {'version': await version(), 'field': 'verifyChecksums', 'value': false});
    expect(verification['status'], 200);
    expect(verification['body']['settings']['verifyChecksums'], false);
    expect(verification['body']['pendingRestart'], ['alias', 'verifyChecksums']);
    expect(listenerVerification, true);
    expect(writes, [('alias', 'Saved name'), ('verifyChecksums', false)]);
    expect(cacheCalls, isEmpty);
    final pendingVersion = await version();
    // Only an external explicit lifecycle transition applies saved listener fields.
    listenerAlias = settings['alias'] as String;
    listenerVerification = settings['verifyChecksums'] as bool;
    final applied = await call('settings.read');
    expect(applied['body']['pendingRestart'], isEmpty);
    expect(applied['body']['version'], isNot(pendingVersion));
    expect(writes, hasLength(2));
  });

  test('listener transition while waiting to claim invalidates an old settings version', () async {
    var pending = ['verifyChecksums'];
    manager = HostManagement(
      readSettings: () => Map.of(settings),
      pendingRestart: () => List.of(pending),
      writeSetting: (field, value) async => writes.add((field, value)),
      cache: (_) async => {'examined': 0},
    );
    final gate = Completer<bool>();
    final enteredClaim = Completer<void>();
    final old = await version();
    final request = call(
      'settings.update',
      change: {'version': old, 'field': 'theme', 'value': 'dark'},
      claim: () {
        enteredClaim.complete();
        return gate.future;
      },
    );
    await enteredClaim.future;
    pending = [];
    gate.complete(true);
    expect((await request)['body']['error']['code'], 'settings_changed');
    expect(writes, isEmpty);
  });
}
