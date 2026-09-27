import 'dart:async';

import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import 'api_fixtures.dart';

void main() {
  late MemoryApiStore store;
  late FakeApiFactory factory;
  late RefenaContainer container;
  late IntegrationApiSettingsNotifier settings;
  setUp(() async {
    store = MemoryApiStore();
    factory = FakeApiFactory();
    container = RefenaContainer(
      overrides: [
        integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: store)),
        integrationApiValidatorProvider.overrideWithValue((_) async {}),
        integrationApiKeyFactoryProvider.overrideWithValue(factory.call),
      ],
    );
    settings = container.notifier(integrationApiSettingsProvider);
    await settings.initialize();
  });
  tearDown(() => container.disposeContainer());
  test('pause and override changes serialize, preserve verifier and retain state on failure', () async {
    await settings.createKey(
      name: 'Key',
      grant: ApiGrant(scopes: [ApiScope.service], workspaces: []),
    );
    await Future.wait([settings.setEnabled(apiKeyId(1), false), settings.setKeyLimits(apiKeyId(1), const ApiLimits(0, 7, 0))]);
    expect(settings.state.keys.single.enabled, false);
    expect(settings.state.keys.single.limits!.perMinute, 7);
    expect(ApiSettings.decode(store.raw).keys.single.enabled, false);
    store.fail = true;
    await expectLater(settings.setEnabled(apiKeyId(1), true), throwsStateError);
    expect(settings.state.keys.single.enabled, false);
    expect(settings.state.keys.single.limits!.perMinute, 7);
    store.fail = false;
    await settings.setEnabled(apiKeyId(1), true);
    await settings.setKeyLimits(apiKeyId(1), null);
    expect(settings.state.keys.single.enabled, true);
    expect(settings.state.keys.single.limits, isNull);
    expect(store.raw, contains('ab' * 32));
  });
  test('create saves before consuming secret and exposes metadata-only state', () async {
    store.gate = Completer<void>();
    final creation = settings.createKey(
      name: 'Automation',
      grant: ApiGrant(scopes: [ApiScope.service], workspaces: []),
    );
    await Future<void>.delayed(Duration.zero);
    expect(factory.drafts.single.reads, 0);
    expect(settings.state.keys, isEmpty);
    store.gate!.complete();
    final secret = await creation;
    expect(factory.drafts.single.reads, 1);
    expect(factory.drafts.single.disposed, true);
    expect(store.raw, isNot(contains(secret)));
    expect(store.raw, contains('verifier'));
    expect(settings.state.keys.single.name, 'Automation');
    expect(settings.state.toString(), isNot(contains(secret)));
    expect(settings.state.toString(), isNot(contains('ab' * 32)));
  });
  test('write failure retains previous policy, consumes no secret and permits retry', () async {
    store.fail = true;
    await expectLater(
      settings.createKey(
        name: 'Failed',
        grant: ApiGrant(scopes: [], workspaces: []),
      ),
      throwsStateError,
    );
    expect(settings.state.keys, isEmpty);
    expect(factory.drafts.single.reads, 0);
    expect(factory.drafts.single.disposed, true);
    expect(settings.state.failed, true);
    store.fail = false;
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    expect(settings.state.failed, false);
    expect(settings.state.policy.enabled, true);
  });
  test('concurrent updates serialize and retain key changes', () async {
    await Future.wait([
      settings.createKey(
        name: 'Key',
        grant: ApiGrant(scopes: [], workspaces: []),
      ),
      settings.updatePolicy((p) => p.copyWith(enabled: true)),
      settings.updatePolicy((p) => p.copyWith(authRequired: false)),
    ]);
    expect(settings.state.keys.length, 1);
    expect(settings.state.policy.enabled, true);
    expect(settings.state.policy.authRequired, false);
    expect(ApiSettings.decode(store.raw).keys.length, 1);
    await settings.rename(apiKeyId(1), 'Renamed');
    await settings.revoke(apiKeyId(1));
    expect(settings.state.keys, isEmpty);
    expect(ApiSettings.decode(store.raw).keys, isEmpty);
  });
  test('restart restores verifier-bearing settings without a recoverable plaintext', () async {
    final secret = await settings.createKey(
      name: 'Persistent',
      grant: ApiGrant(scopes: [ApiScope.service], workspaces: []),
    );
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    final next = RefenaContainer(
      overrides: [
        integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: store)),
        integrationApiValidatorProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(next.disposeContainer);
    final restored = next.notifier(integrationApiSettingsProvider);
    await restored.initialize();
    expect(restored.state.policy.enabled, true);
    expect(restored.state.keys.single.name, 'Persistent');
    expect(restored.configuration(4), isNot(contains(secret)));
    expect(restored.state.toString(), isNot(contains(secret)));
  });
  test('invalid persisted settings remain untouched until explicit reset', () async {
    final bad = MemoryApiStore('RAW-SECRET-BROKEN');
    final next = RefenaContainer(
      overrides: [
        integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: bad)),
        integrationApiValidatorProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(next.disposeContainer);
    final broken = next.notifier(integrationApiSettingsProvider);
    await broken.initialize();
    expect(broken.state.corrupt, true);
    expect(bad.raw, 'RAW-SECRET-BROKEN');
    expect(bad.writes, 0);
    await expectLater(broken.updatePolicy((p) => p.copyWith(enabled: true)), throwsStateError);
    await broken.reset();
    expect(broken.state.corrupt, false);
    expect(ApiSettings.decode(bad.raw).policy.enabled, false);
  });
  test('core validator rejection never writes invalid policy or changes published intent', () async {
    await container.set(integrationApiValidatorProvider.overrideWithValue((_) async => throw StateError('fixture rejection')));
    final previous = settings.state.generation;
    await expectLater(settings.updatePolicy((p) => p.copyWith(enabled: true)), throwsStateError);
    expect(store.writes, 0);
    expect(settings.state.generation, previous);
    expect(settings.state.policy.enabled, false);
  });
}
