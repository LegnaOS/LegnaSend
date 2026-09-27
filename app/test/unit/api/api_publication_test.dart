import 'dart:async';

import 'package:localsend_app/provider/integration_api_publication_provider.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import 'api_fixtures.dart';

void main() {
  late RefenaContainer container;
  late IntegrationApiSettingsNotifier settings;
  late ApiTestServer server;
  late IntegrationApiPublicationNotifier publication;
  setUp(() async {
    server = ApiTestServer();
    container = RefenaContainer(
      overrides: [
        integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: MemoryApiStore())),
        integrationApiValidatorProvider.overrideWithValue((_) async {}),
        serverProvider.overrideWithNotifier((_) => server),
      ],
    );
    settings = container.notifier(integrationApiSettingsProvider);
    await settings.initialize();
    publication = container.notifier(integrationApiPublicationProvider);
    await publication.synchronize();
  });
  tearDown(() => container.disposeContainer());
  test('actual snapshot confirms saved generation, port and disabled defaults', () {
    expect(publication.state.runtime!.port, 54199);
    expect(publication.state.runtime!.policy.enabled, false);
    expect(publication.state.appliedGeneration, settings.state.generation);
  });
  test('failed disable retains active policy until acknowledged retry', () async {
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    await publication.synchronize();
    server.fail = true;
    await settings.updatePolicy((p) => p.copyWith(enabled: false));
    await publication.synchronize();
    expect(settings.state.policy.enabled, false);
    expect(publication.state.runtime!.policy.enabled, true);
    expect(publication.state.failed, true);
    server.fail = false;
    await publication.synchronize();
    expect(publication.state.runtime!.policy.enabled, false);
    expect(publication.state.failed, false);
  });
  test('late updates drain without calling the saved policy active early', () async {
    server.gate = Completer<void>();
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    final first = publication.synchronize();
    await Future<void>.delayed(Duration.zero);
    expect(publication.state.runtime!.policy.enabled, false);
    expect(publication.state.busy, true);
    await settings.updatePolicy((p) => p.copyWith(authRequired: false));
    server.gate!.complete();
    await first;
    expect(publication.state.runtime!.policy.enabled, true);
    expect(publication.state.runtime!.policy.authRequired, false);
    expect(publication.state.appliedGeneration, settings.state.generation);
  });
  test('listener change discards old response and reapplies to the new instance', () async {
    server.gate = Completer<void>();
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    final first = publication.synchronize();
    await Future<void>.delayed(Duration.zero);
    server.epoch++;
    server.gate!.complete();
    await first;
    expect(publication.state.failed, false);
    expect(publication.state.runtime!.instanceId, apiKeyId(server.epoch));
    expect(publication.state.runtime!.policy.enabled, true);
  });
  test('reconnected listener revision is read before applying saved policy', () async {
    server.config['revision'] = 999;
    server.epoch++;
    await publication.synchronize();
    expect(publication.state.failed, false);
    expect(server.requests.last['revision'], 1000);
    expect(publication.state.runtime!.revision, 1000);
  });

  test('refresh reads live metadata without rewriting policy; bad acknowledgements stay pending', () async {
    final count = server.requests.length;
    final reads = server.snapshots;
    await publication.synchronize(refresh: true);
    expect(server.requests.length, count);
    expect(server.snapshots, reads + 1);
    server.badAck = true;
    await settings.updatePolicy((p) => p.copyWith(enabled: true));
    await publication.synchronize();
    expect(publication.state.failed, true);
    expect(publication.state.runtime!.policy.enabled, false);
    server.badAck = false;
    await publication.synchronize();
    expect(publication.state.runtime!.policy.enabled, true);
  });
}
