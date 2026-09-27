import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/api/key_management.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'api_fixtures.dart';

class _UncertainStore extends MemoryApiStore {
  bool commitThenThrow = false;
  _UncertainStore(super.raw);
  @override
  Future<void> write(String value) async {
    await super.write(value);
    if (commitThenThrow) throw StateError('acknowledgement lost after durable write');
  }
}

void main() {
  late MemoryApiStore store;
  late RefenaContainer container;
  late IntegrationApiSettingsNotifier manager;
  final grant = ApiGrant(scopes: [ApiScope.keysManage, ApiScope.service], workspaces: ['*']);
  int serial = 100;
  var publishes = 0;
  bool applied = true;
  Future<Map<String, dynamic>> call(
    String op, {
    Map<String, Object?>? body,
    String? keyId,
    String? requestId,
    Future<bool> Function()? claim,
  }) async =>
      jsonDecode(
            await manager.manageKeys(
              request: jsonEncode({
                'operation': 'keys.$op',
                'principal': apiKeyId(1),
                'grant': grant.toJson(),
                'change': ?body,
                'keyId': ?keyId,
                'requestId': ?requestId,
              }),
              claim: claim ?? () async => true,
              publish: () async {
                publishes++;
                return applied;
              },
            ),
          )
          as Map<String, dynamic>;
  Future<String> version() async => (await call('list'))['body']['version'] as String;
  Future<Map<String, Object?>> createBody({List<ApiScope> scopes = const [ApiScope.service], String? id}) async => {
    'version': await version(),
    'requestId': id ?? apiKeyId(serial++),
    'name': 'Child',
    'grant': ApiGrant(scopes: scopes, workspaces: ['*']).toJson(),
    'expiresAt': null,
  };
  void bind() {
    container = RefenaContainer(
      overrides: [
        integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: store)),
        integrationApiValidatorProvider.overrideWithValue((_) async {}),
        integrationApiKeyFactoryProvider.overrideWithValue(
          ({required name, required grant, int? expiresAt}) async =>
              FakeApiDraft(apiRecord(serial++, name: name, grant: ApiGrant.fromJson(jsonDecode(grant)), expiry: expiresAt)),
        ),
      ],
    );
    manager = container.notifier(integrationApiSettingsProvider);
  }

  setUp(() async {
    serial = 100;
    publishes = 0;
    applied = true;
    store = _UncertainStore(ApiSettings.defaults().addRecord(jsonEncode(apiRecord(1, grant: grant))).encode());
    bind();
    await manager.initialize();
  });
  tearDown(() => container.disposeContainer());
  test('create persists receipt and key together before one-time secret, replay across restart never recreates or re-emits', () async {
    final body = await createBody();
    final first = await call('create', body: body);
    expect(first['status'], 201);
    final secret = first['body']['secret'] as String;
    expect(secret, startsWith('ls1.'));
    expect(store.raw, isNot(contains(secret)));
    expect(manager.state.toString(), isNot(contains(secret)));
    expect(manager.state.keys, hasLength(2));
    final disk = ApiSettings.decode(store.raw);
    expect(disk.keyReceipts, hasLength(1));
    expect(disk.keyReceipts.single['keyId'], first['body']['receipt']['keyId']);
    container.disposeContainer();
    bind();
    await manager.initialize();
    final replay = await call('create', body: body);
    expect(replay['status'], 200);
    expect(replay['body']['secretAvailable'], false);
    expect(replay['body'].containsKey('secret'), false);
    expect(manager.state.keys, hasLength(2));
    final receipt = await call('receipt', requestId: body['requestId'] as String);
    expect(receipt['body']['receipt'], first['body']['receipt']);
  });
  test('same id with different intent conflicts and stale new request version cannot mutate', () async {
    final body = await createBody();
    await call('create', body: body);
    expect((await call('create', body: {...body, 'name': 'changed'}))['body']['error']['code'], 'request_id_conflict');
    expect((await call('create', body: {...body, 'requestId': apiKeyId(serial++)}))['body']['error']['code'], 'keys_changed');
    expect(manager.state.keys, hasLength(2));
  });
  test('scope escalation self-control and caller pause never reach mutation', () async {
    final body = await createBody(scopes: [ApiScope.settingsWrite]);
    expect((await call('create', body: body))['status'], 403);
    expect(
      (await call(
        'manage',
        keyId: apiKeyId(1),
        body: {'version': await version(), 'requestId': apiKeyId(serial++), 'action': 'revoke'},
      ))['body']['error']['code'],
      'self_management_forbidden',
    );
    await manager.setEnabled(apiKeyId(1), false);
    expect((await call('list'))['status'], 403);
    expect(manager.state.keys, hasLength(1));
  });
  test('pause resume revoke are durable with replayable receipts and no verifier exposure', () async {
    final created = await call('create', body: await createBody());
    final id = created['body']['receipt']['keyId'] as String;
    for (final action in ['pause', 'resume', 'revoke']) {
      final body = <String, Object?>{'version': await version(), 'requestId': apiKeyId(serial++), 'action': action};
      final result = await call('manage', keyId: id, body: body);
      expect(result['status'], 200);
      expect(result['body']['receipt']['action'], action);
      expect((await call('manage', keyId: id, body: body))['status'], 200);
      if (action != 'revoke') expect(manager.state.keys.singleWhere((k) => k.id == id).enabled, action == 'resume');
    }
    expect(manager.state.keys, hasLength(1));
    expect(ApiSettings.decode(store.raw).keyReceipts, hasLength(4));
    expect(jsonEncode(await call('list')), isNot(contains('verifier')));
  });
  test('failed publication persists receipt without secret and original request reconciles later', () async {
    applied = false;
    final body = await createBody();
    final result = await call('create', body: body);
    expect(result['body']['applied'], false);
    expect(result['body']['secretAvailable'], false);
    applied = true;
    final replay = await call('create', body: body);
    expect(replay['body']['applied'], true);
    expect(replay['body']['secretAvailable'], false);
    expect(manager.state.keys, hasLength(2));
    expect(publishes, 2);
  });
  test('persistence failure publishes nothing and leaves no partial key or receipt', () async {
    final body = await createBody();
    store.fail = true;
    final result = await call('create', body: body);
    expect(result['status'], 503);
    expect(manager.state.keys, hasLength(1));
    expect(ApiSettings.decode(store.raw).keyReceipts, isEmpty);
    expect(publishes, 0);
  });
  test('expired claim creates no persistent key and local edit queues behind remote operation', () async {
    final body = await createBody();
    expect((await call('create', body: body, claim: () async => false))['status'], 409);
    expect(manager.state.keys, hasLength(1));
    final gate = Completer<bool>();
    final entered = Completer<void>();
    final pending = call(
      'create',
      body: body,
      claim: () {
        entered.complete();
        return gate.future;
      },
    );
    await entered.future;
    final rename = manager.rename(apiKeyId(1), 'Locally edited');
    gate.complete(true);
    expect((await pending)['status'], 201);
    await rename;
    expect(manager.state.keys.first.name, 'Locally edited');
    expect(ApiSettings.decode(store.raw).keyReceipts, hasLength(1));
  });
  test('write committed but acknowledgement lost reconciles receipt before allowing replay', () async {
    final body = await createBody();
    (store as _UncertainStore).commitThenThrow = true;
    final failed = await call('create', body: body);
    expect(failed['status'], 503);
    expect(manager.state.keys, hasLength(2));
    expect(ApiSettings.decode(store.raw).keyReceipts, hasLength(1));
    (store as _UncertainStore).commitThenThrow = false;
    final replay = await call('create', body: body);
    expect(replay['status'], 200);
    expect(replay['body']['secretAvailable'], false);
    expect(manager.state.keys, hasLength(2));
    expect(store.writes, 1);
  });
  test('receipt capacity preserves reconciliation and rejects new mutations without eviction', () async {
    container.disposeContainer();
    var stored = ApiSettings.decode(store.raw);
    for (var index = 0; index < 256; index++) {
      stored = stored.withKeyReceipt(
        apiKeyReceipt(
          principal: apiKeyId(1),
          requestId: apiKeyId(1000 + index),
          digest: 'a' * 64,
          action: 'revoke',
          keyId: apiKeyId(5000 + index),
          createdAt: 1,
        ),
      );
    }
    store.raw = stored.encode();
    bind();
    await manager.initialize();
    final result = await call('create', body: await createBody());
    expect(result['status'], 409);
    expect(result['body']['error']['code'], 'receipt_capacity');
    expect(manager.state.keys, hasLength(1));
    expect(ApiSettings.decode(store.raw).keyReceipts, hasLength(256));
    expect((await call('receipt', requestId: apiKeyId(1000)))['status'], 200);
    expect(store.writes, 0);
  });
  test('finite caller expiry bounds delegated lifetime including unlimited requests', () async {
    container.disposeContainer();
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    store.raw = ApiSettings.defaults().addRecord(jsonEncode(apiRecord(1, grant: grant, expiry: expiry))).encode();
    bind();
    await manager.initialize();
    final body = await createBody();
    expect((await call('create', body: body))['status'], 403);
    expect((await call('create', body: {...body, 'expiresAt': expiry + 1}))['status'], 403);
    expect((await call('create', body: {...body, 'expiresAt': expiry}))['status'], 201);
    expect(manager.state.keys, hasLength(2));
  });
}
