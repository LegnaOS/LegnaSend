import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/api/key_management.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_isolates/util/integration_api.dart';
import 'package:refena_flutter/refena_flutter.dart';

final integrationApiSettingsProvider = NotifierProvider<IntegrationApiSettingsNotifier, IntegrationApiSettingsState>(
  (_) => IntegrationApiSettingsNotifier(),
);

typedef ApiKeyFactory = Future<IntegrationApiKeyDraft> Function({required String name, required String grant, int? expiresAt});
final integrationApiKeyFactoryProvider = Provider<ApiKeyFactory>((_) => createIntegrationApiKeyDraft);
final integrationApiValidatorProvider = Provider<Future<void> Function(String)>((_) => validateIntegrationApiSettings);

abstract interface class IntegrationApiSettingsStore {
  Future<String?> read();
  Future<void> write(String value);
}

class IntegrationApiSettingsState {
  final bool initialized;
  final bool corrupt;
  final bool saving;
  final bool failed;
  final int generation;
  final ApiPolicy policy;
  final List<ApiKeyMetadata> keys;
  IntegrationApiSettingsState({
    this.initialized = false,
    this.corrupt = false,
    this.saving = false,
    this.failed = false,
    this.generation = 0,
    ApiPolicy? policy,
    this.keys = const [],
  }) : policy = policy ?? ApiPolicy();
  @override
  String toString() => 'IntegrationApiSettingsState(loaded: $initialized, keys: ${keys.length}, generation: $generation)';
}

/// Verifiers live only in this owner's private config, not observable provider state.
class IntegrationApiSettingsNotifier extends Notifier<IntegrationApiSettingsState> {
  final IntegrationApiSettingsStore? store;
  final AsyncSerialQueue _queue = AsyncSerialQueue();
  ApiSettings _settings = ApiSettings.defaults();
  bool _disposed = false;
  late final IntegrationApiSettingsStore _store;
  IntegrationApiSettingsNotifier({this.store});
  @override
  IntegrationApiSettingsState init() {
    _store = store ?? _PreferencesApiStore(ref.read(persistenceProvider));
    return IntegrationApiSettingsState();
  }

  void _emit({bool? initialized, bool corrupt = false, bool saving = false, bool failed = false, int? generation}) {
    if (_disposed) return;
    state = IntegrationApiSettingsState(
      initialized: initialized ?? state.initialized,
      corrupt: corrupt,
      saving: saving,
      failed: failed,
      generation: generation ?? state.generation,
      policy: _settings.policy,
      keys: _settings.keys,
    );
  }

  Future<void> initialize() => _queue.run(() async {
    if (state.initialized || _disposed) return;
    try {
      final loaded = ApiSettings.decode(await _store.read());
      await ref.read(integrationApiValidatorProvider)(loaded.configuration(1));
      _settings = loaded;
      _emit(initialized: true, generation: state.generation + 1);
    } catch (_) {
      // Preserve corrupt/unsupported settings on disk until explicit reset/retry.
      _emit(initialized: true, corrupt: true, failed: true);
    }
  });
  Future<void> retryLoad() => _queue.run(() async {
    if (_disposed || !state.corrupt) return;
    try {
      final loaded = ApiSettings.decode(await _store.read());
      await ref.read(integrationApiValidatorProvider)(loaded.configuration(1));
      _settings = loaded;
      _emit(initialized: true, generation: state.generation + 1);
    } catch (_) {
      _emit(initialized: true, corrupt: true, failed: true);
    }
  });
  Future<void> _persist(ApiSettings next, {bool resetting = false}) async {
    if (_disposed || !state.initialized || (state.corrupt && !resetting)) throw StateError('API settings are not ready');
    final corrupt = state.corrupt;
    _emit(corrupt: corrupt, saving: true);
    try {
      await ref.read(integrationApiValidatorProvider)(next.configuration(1));
      await _store.write(next.encode());
      _settings = next;
      _emit(generation: state.generation + 1);
    } catch (_) {
      _emit(corrupt: corrupt, failed: true);
      throw StateError('API settings were not saved');
    }
  }

  Future<void> updatePolicy(ApiPolicy Function(ApiPolicy) update) => _queue.run(() => _persist(_settings.withPolicy(update(_settings.policy))));
  Future<void> revoke(String id) => _queue.run(() => _persist(_settings.revoke(id)));
  Future<void> setEnabled(String id, bool enabled) => _queue.run(() => _persist(_settings.setEnabled(id, enabled)));
  Future<void> setKeyLimits(String id, ApiLimits? limits) => _queue.run(() => _persist(_settings.setKeyLimits(id, limits)));
  Future<void> rename(String id, String name) => _queue.run(() => _persist(_settings.rename(id, name)));
  Future<void> reset() => _queue.run(() => _persist(ApiSettings.defaults(), resetting: true));

  /// The returned secret is never placed in provider state, diagnostics or storage.
  Future<String> createKey({required String name, required ApiGrant grant, int? expiresAt}) => _queue.run(() async {
    if (_disposed || !state.initialized || state.corrupt) throw StateError('API settings are not ready');
    final draft = await ref.read(integrationApiKeyFactoryProvider)(name: name, grant: jsonEncode(grant.toJson()), expiresAt: expiresAt);
    try {
      final next = _settings.addRecord(await draft.persistenceRecord());
      await _persist(next);
      final secret = await draft.takeSecret();
      if (secret == null) throw StateError('API key is no longer available');
      return secret;
    } finally {
      draft.dispose();
    }
  });

  /// Remote lifecycle mutations share the same serial persistence owner as
  /// local edits. Durable intent and its replay receipt are one stored value.
  Future<String> manageKeys({required String request, required Future<bool> Function() claim, required Future<bool> Function() publish}) =>
      _queue.run(() async {
        String response(int status, Map<String, Object?> body) => jsonEncode({'status': status, 'body': body});
        String fail(int status, String code) => response(status, {
          'error': {'code': code},
        });
        IntegrationApiKeyDraft? draft;
        try {
          if (_disposed || !state.initialized || state.corrupt) return fail(503, 'keys_unavailable');
          final input = jsonDecode(request) as Map<String, dynamic>;
          final principal = input['principal'] as String;
          final operation = input['operation'] as String;
          ApiKeyMetadata caller() {
            final key = _settings.keys.where((key) => key.id == principal).firstOrNull;
            if (key == null ||
                !key.enabled ||
                key.expired ||
                !key.grant.scopes.contains(ApiScope.keysManage) ||
                !key.grant.workspaces.contains('*')) {
              throw const ApiKeyManagementException(403, 'keys_authority_changed');
            }
            return key;
          }

          final actor = caller();
          final visible = _settings.keys.where((key) => apiGrantContains(actor.grant, key.grant)).toList();
          if (operation == 'keys.list') {
            if (!await claim()) return fail(409, 'operation_expired');
            caller();
            return response(200, {'version': apiKeySetVersion(_settings), 'keys': visible.map(apiKeyMetadataJson).toList()});
          }
          if (operation == 'keys.receipt') {
            if (!await claim()) return fail(409, 'operation_expired');
            caller();
            final receipt = _settings.keyReceipts.where((r) => r['principal'] == principal && r['requestId'] == input['requestId']).firstOrNull;
            if (receipt == null) return fail(404, 'receipt_not_found');
            return response(200, {'receipt': receipt, 'applied': await publish(), 'secretAvailable': false});
          }
          if (!['keys.create', 'keys.manage'].contains(operation)) return fail(400, 'invalid_operation');
          final change = Map<String, dynamic>.from(input['change'] as Map);
          final requestId = change['requestId'] as String;
          final version = change['version'] as String;
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version) ||
              !RegExp(r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$').hasMatch(requestId)) {
            return fail(400, 'invalid_body');
          }
          final canonical = <String, Object?>{
            'operation': operation,
            'keyId': input['keyId'],
            for (final key in change.keys.toList()..sort()) key: change[key],
          };
          final digest = sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
          final previous = _settings.keyReceipts.where((r) => r['principal'] == principal && r['requestId'] == requestId).firstOrNull;
          if (previous != null) {
            if (previous['digest'] != digest) return fail(409, 'request_id_conflict');
            if (!await claim()) return fail(409, 'operation_expired');
            caller();
            return response(200, {'receipt': previous, 'applied': await publish(), 'secretAvailable': false});
          }
          if (_settings.keyReceipts.length >= 256) return fail(409, 'receipt_capacity');
          if (version != apiKeySetVersion(_settings)) return fail(409, 'keys_changed');
          final create = operation == 'keys.create';
          final action = create ? 'create' : change['action'] as String;
          String keyId;
          ApiSettings next;
          if (create) {
            if (change.keys.toSet().difference({'requestId', 'version', 'name', 'grant', 'expiresAt'}).isNotEmpty || change.length != 5) {
              return fail(400, 'invalid_body');
            }
            final grant = ApiGrant.fromJson(change['grant']);
            final expires = change['expiresAt'];
            if (!isApiKeyNameValid(change['name'] as String) ||
                !apiGrantContains(actor.grant, grant) ||
                (expires != null && (expires is! int || expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000)) ||
                (actor.expiresAt != null && (expires == null || expires > actor.expiresAt))) {
              return fail(403, 'grant_escalation');
            }
            draft = await ref.read(integrationApiKeyFactoryProvider)(
              name: change['name'] as String,
              grant: jsonEncode(grant.toJson()),
              expiresAt: expires as int?,
            );
            final record = await draft.persistenceRecord();
            keyId = (jsonDecode(record) as Map)['id'] as String;
            next = _settings.addRecord(record);
          } else {
            if (change.keys.toSet().difference({'requestId', 'version', 'action'}).isNotEmpty ||
                change.length != 3 ||
                !['pause', 'resume', 'revoke'].contains(action)) {
              return fail(400, 'invalid_body');
            }
            keyId = input['keyId'] as String;
            if (keyId == principal) return fail(403, 'self_management_forbidden');
            final target = visible.where((key) => key.id == keyId).firstOrNull;
            if (target == null) return fail(404, 'key_not_found');
            if (action == 'resume' && target.expired) return fail(409, 'key_expired');
            if (action == 'resume' && actor.expiresAt != null && (target.expiresAt == null || target.expiresAt! > actor.expiresAt!)) {
              return fail(403, 'grant_escalation');
            }
            next = action == 'revoke' ? _settings.revoke(keyId) : _settings.setEnabled(keyId, action == 'resume');
          }
          if (!await claim()) return fail(409, 'operation_expired');
          caller();
          if (version != apiKeySetVersion(_settings)) return fail(409, 'keys_changed');
          final receipt = apiKeyReceipt(
            principal: principal,
            requestId: requestId,
            digest: digest,
            action: action,
            keyId: keyId,
            createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
          try {
            await _persist(next.withKeyReceipt(receipt));
          } catch (_) {
            // A platform store may commit and then fail its acknowledgement. Read
            // back before permitting another intent; otherwise replay could create
            // a second key while the first receipt is already durable on disk.
            try {
              final persisted = ApiSettings.decode(await _store.read());
              await ref.read(integrationApiValidatorProvider)(persisted.configuration(1));
              _settings = persisted;
              _emit(generation: state.generation + 1, failed: true);
            } catch (_) {
              _emit(corrupt: true, failed: true);
            }
            return fail(503, 'key_operation_failed');
          }
          caller();
          final applied = await publish();
          if (!applied) return response(200, {'receipt': receipt, 'applied': false, 'secretAvailable': false});
          caller(); // Publication may have outlived the caller expiry. Never deliver a secret then.
          final secret = await draft?.takeSecret();
          return response(create ? 201 : 200, {
            'receipt': receipt,
            'applied': true,
            'secretAvailable': secret != null,
            'secret': ?secret,
          });
        } on ApiKeyManagementException catch (error) {
          return fail(error.status, error.code);
        } on FormatException {
          return fail(400, 'invalid_body');
        } on TypeError {
          return fail(400, 'invalid_body');
        } catch (_) {
          return fail(503, 'key_operation_failed');
        } finally {
          draft?.dispose();
        }
      });

  /// Only the publication controller requests this verifier-bearing transport.
  String configuration(int revision) => _settings.configuration(revision);
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _PreferencesApiStore implements IntegrationApiSettingsStore {
  final PersistenceService persistence;
  _PreferencesApiStore(this.persistence);
  @override
  Future<String?> read() async => persistence.getIntegrationApiSettings();
  @override
  Future<void> write(String value) => persistence.setIntegrationApiSettings(value);
}
