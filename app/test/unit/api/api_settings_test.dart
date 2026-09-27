import 'dart:convert';

import 'package:localsend_app/util/api/api_settings.dart';
import 'package:test/test.dart';

import 'api_fixtures.dart';

void main() {
  test('legacy records migrate to enabled inherited limits and v2 without changing verifier', () {
    final legacy = jsonDecode(ApiSettings.defaults().addRecord(jsonEncode(apiRecord(1))).encode());
    legacy['version'] = 1;
    legacy['settings']['keys'][0].remove('enabled');
    legacy['settings']['keys'][0].remove('limits');
    final settings = ApiSettings.decode(jsonEncode(legacy));
    expect(settings.keys.single.enabled, true);
    expect(settings.keys.single.limits, isNull);
    expect(jsonDecode(settings.encode())['version'], 2);
    final changed = settings.setEnabled(apiKeyId(1), false).setKeyLimits(apiKeyId(1), const ApiLimits(0, 0, 0));
    final saved = ApiSettings.decode(changed.encode());
    expect(saved.keys.single.enabled, false);
    expect(saved.keys.single.limits!.concurrent, 0);
    expect(jsonDecode(saved.configuration(3))['keys'][0]['verifier'], 'ab' * 32);
    final resumed = saved.setEnabled(apiKeyId(1), true).setKeyLimits(apiKeyId(1), null);
    expect(resumed.keys.single.enabled, true);
    expect(resumed.keys.single.limits, isNull);
    expect(resumed.keys.single.id, settings.keys.single.id);
  });
  test('zero dimensions accepted everywhere and malformed overrides rejected', () {
    final policy = ApiPolicy(globalLimits: const ApiLimits(0, 1, 0), keyLimits: const ApiLimits(1, 0, 0), anonymousLimits: const ApiLimits(0, 0, 1));
    expect(ApiPolicy.fromJson(policy.toJson()).globalLimits.perSecond, 0);
    for (final bad in [
      false,
      {},
      {'perSecond': -1, 'perMinute': 0, 'concurrent': 0},
      {'perSecond': 0, 'perMinute': 0, 'concurrent': 65},
    ]) {
      expect(() => ApiSettings.defaults().addRecord(jsonEncode({...apiRecord(1), 'limits': bad})), throwsFormatException);
    }
    for (final bad in [null, 'false', 0]) {
      expect(() => ApiSettings.defaults().addRecord(jsonEncode({...apiRecord(1), 'enabled': bad})), throwsFormatException);
    }
  });
  test('defaults and bounded settings roundtrip preserve verifier but not plaintext', () {
    final settings = ApiSettings.defaults().addRecord(jsonEncode(apiRecord(1)));
    final decoded = ApiSettings.decode(settings.encode());
    expect(decoded.policy.enabled, false);
    expect(decoded.policy.authRequired, true);
    expect(decoded.policy.globalLimits.perSecond, 30);
    expect(decoded.policy.anonymousGrant.workspaces, ['*']);
    expect(decoded.keys.single.id, apiKeyId(1));
    expect(jsonDecode(decoded.configuration(77))['revision'], 77);
    expect(decoded.encode(), settings.encode());
    expect(decoded.toString(), isNot(contains('ab' * 32)));
    expect(decoded.keys.single.toString(), isNot(contains('ab' * 32)));
    expect(decoded.encode(), isNot(contains('ls1.')));
  });
  test('reject unknown versions, fields, plaintext extras and oversized files without echo', () {
    for (final raw in ['SECRET raw', '{"version":2,"settings":{}}', '${' ' * ApiSettings.maxBytes}x']) {
      expect(() => ApiSettings.decode(raw), throwsFormatException);
    }
    final envelope = jsonDecode(ApiSettings.defaults().encode());
    envelope['settings']['token'] = 'SECRET';
    expect(() => ApiSettings.decode(jsonEncode(envelope)), throwsFormatException);
    final record = apiRecord(1)..['secret'] = 'SECRET';
    expect(() => ApiSettings.defaults().addRecord(jsonEncode(record)), throwsFormatException);
  });
  test('enforce all three limits, anonymous scope restrictions and origin shape', () {
    for (final limits in [const ApiLimits(-1, 1, 1), const ApiLimits(1, 60001, 1), const ApiLimits(1, 1, 65)]) {
      expect(() => ApiPolicy(globalLimits: limits), throwsFormatException);
    }
    expect(
      () => ApiPolicy(
        anonymousGrant: ApiGrant(scopes: [ApiScope.requests], workspaces: []),
      ),
      throwsFormatException,
    );
    for (final origin in ['*', 'https://a/b', 'https://user:password@a', 'file://host', 'https://a?token=x']) {
      expect(() => ApiPolicy(allowedOrigins: [origin]), throwsFormatException);
    }
    expect(ApiPolicy(allowedOrigins: ['https://client.example']).allowedOrigins.single, 'https://client.example');
  });
  test('upload grants are explicit, persist only on keys and never become anonymous writes', () {
    final defaults = ApiSettings.defaults();
    expect(defaults.policy.anonymousGrant.scopes, isNot(contains(ApiScope.upload)));
    final readKey = defaults.addRecord(jsonEncode(apiRecord(1)));
    expect(readKey.keys.single.grant.scopes, isNot(contains(ApiScope.upload)));
    final grant = ApiGrant(scopes: [ApiScope.upload], workspaces: [apiKeyId(2)]);
    final writable = defaults.addRecord(jsonEncode(apiRecord(2, grant: grant)));
    expect(ApiSettings.decode(writable.encode()).keys.single.grant.scopes, [ApiScope.upload]);
    expect(writable.keys.single.grant.workspaces, [apiKeyId(2)]);
    expect(grant.toJson()['scopes'], ['files.upload']);
    for (final required in [true, false]) {
      expect(() => ApiPolicy(authRequired: required, anonymousGrant: grant), throwsFormatException);
    }
  });

  test('management grants persist explicitly and never become anonymous or default permissions', () {
    final grant = ApiGrant(scopes: [ApiScope.manage], workspaces: [apiKeyId(2)]);
    final settings = ApiSettings.defaults().addRecord(jsonEncode(apiRecord(2, grant: grant)));
    expect(ApiSettings.decode(settings.encode()).keys.single.grant.scopes, [ApiScope.manage]);
    expect(grant.toJson()['scopes'], ['workspaces.manage']);
    expect(ApiSettings.defaults().policy.anonymousGrant.scopes, isNot(contains(ApiScope.manage)));
    for (final auth in [true, false]) {
      expect(() => ApiPolicy(authRequired: auth, anonymousGrant: grant), throwsFormatException);
    }
  });

  test('grants are immutable and reject duplicate scopes, identities and wildcard mixes', () {
    final scopes = [ApiScope.files];
    final ids = [apiKeyId(1)];
    final grant = ApiGrant(scopes: scopes, workspaces: ids);
    scopes.clear();
    ids.clear();
    expect(grant.scopes, [ApiScope.files]);
    expect(grant.workspaces, [apiKeyId(1)]);
    expect(() => grant.workspaces.add('*'), throwsUnsupportedError);
    for (final ids in [
      ['*', apiKeyId(1)],
      ['x'],
      [apiKeyId(1), apiKeyId(1)],
    ]) {
      expect(() => ApiGrant(scopes: [], workspaces: ids), throwsFormatException);
    }
    expect(() => ApiGrant(scopes: [ApiScope.files, ApiScope.files], workspaces: []), throwsFormatException);
  });
  test('key metadata edits preserve verifier, revocation removes only the selected key', () {
    final settings = ApiSettings.defaults().addRecord(jsonEncode(apiRecord(1))).addRecord(jsonEncode(apiRecord(2)));
    final renamed = settings.rename(apiKeyId(1), '重命名');
    expect(renamed.keys.first.name, '重命名');
    expect(settings.keys.first.name, 'Test key');
    expect(jsonDecode(renamed.configuration(1))['keys'][0]['verifier'], 'ab' * 32);
    expect(renamed.revoke(apiKeyId(1)).keys.single.id, apiKeyId(2));
    expect(() => renamed.rename(apiKeyId(1), '\n'), throwsFormatException);
    expect(() => renamed.addRecord(jsonEncode(apiRecord(1))), throwsFormatException);
  });
  test('malformed records and excessive key count fail before persistence', () {
    for (final change in [
      {'verifier': 'x'},
      {'id': 'x'},
      {'createdAt': -1},
      {'expiresAt': -2},
      {'name': '中' * 86},
    ]) {
      expect(() => ApiSettings.defaults().addRecord(jsonEncode({...apiRecord(1), ...change})), throwsFormatException);
    }
    var settings = ApiSettings.defaults();
    for (var i = 1; i <= 128; i++) {
      settings = settings.addRecord(jsonEncode(apiRecord(i)));
    }
    expect(settings.keys.length, 128);
    expect(() => settings.addRecord(jsonEncode(apiRecord(129))), throwsFormatException);
  });
}
