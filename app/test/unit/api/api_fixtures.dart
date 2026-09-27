import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_isolates/util/integration_api.dart';

String apiKeyId(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
Map<String, dynamic> apiRecord(int n, {String name = 'Test key', ApiGrant? grant, int? expiry}) => {
  'id': apiKeyId(n),
  'name': name,
  'grant': (grant ?? ApiGrant(scopes: [ApiScope.service], workspaces: [])).toJson(),
  'verifier': 'ab' * 32,
  'createdAt': 1,
  'expiresAt': expiry,
};

class MemoryApiStore implements IntegrationApiSettingsStore {
  String? raw;
  bool fail = false;
  int writes = 0;
  Completer<void>? gate;
  MemoryApiStore([this.raw]);
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String value) async {
    writes++;
    await gate?.future;
    if (fail) throw StateError('fixture store failure');
    raw = value;
  }
}

class FakeApiDraft implements IntegrationApiKeyDraft {
  final Map<String, dynamic> record;
  bool disposed = false;
  int reads = 0;
  FakeApiDraft(this.record);
  String get secret => 'ls1.${record['id']}.${'a' * 43}';
  @override
  Future<String> persistenceRecord() async => jsonEncode(record);
  @override
  Future<String?> takeSecret() async => reads++ == 0 ? secret : null;
  @override
  void dispose() {
    disposed = true;
  }

  @override
  String toString() => 'FakeApiDraft(redacted)';
}

class FakeApiFactory {
  final drafts = <FakeApiDraft>[];
  Future<IntegrationApiKeyDraft> call({required String name, required String grant, int? expiresAt}) async {
    final draft = FakeApiDraft(apiRecord(drafts.length + 1, name: name, grant: ApiGrant.fromJson(jsonDecode(grant)), expiry: expiresAt));
    drafts.add(draft);
    return draft;
  }
}

class ApiTestServer extends ServerService {
  bool fail = false;
  bool badAck = false;
  final bool online;
  int epoch = 1;
  int snapshots = 0;
  Completer<void>? gate;
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> config = jsonDecode(ApiSettings.defaults().configuration(0));
  ApiTestServer({this.online = true});
  @override
  int get generation => epoch;
  @override
  ServerState? init() => online ? const ServerState(alias: 'Fixture', port: 54199, https: false, session: null, web: null) : null;
  @override
  Future<String> integrationApiControl({required int expectedGeneration, String? configuration}) async {
    if (configuration != null) {
      final next = jsonDecode(configuration) as Map<String, dynamic>;
      requests.add(next);
      await gate?.future;
      if (fail) throw StateError('fixture apply failure');
      if (expectedGeneration != epoch) throw StateError('listener changed');
      config = next;
      return jsonEncode({'revision': badAck ? -1 : next['revision'], 'enabled': next['enabled'], 'keys': (next['keys'] as List).length});
    }
    snapshots++;
    if (fail) throw StateError('fixture snapshot failure');
    return jsonEncode({
      ...config,
      'instanceId': apiKeyId(epoch),
      'port': 54199,
      'activeResponses': 0,
      'recordCount': 0,
      'keys': [for (final key in config['keys']) Map.of(key)..remove('verifier')],
    });
  }
}
