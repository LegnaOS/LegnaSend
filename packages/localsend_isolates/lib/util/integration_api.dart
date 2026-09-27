import 'package:localsend_isolates/rust/api/integration.dart' as rust;

/// Opaque ownership prevents generated serializers from exposing plaintext.
abstract interface class IntegrationApiKeyDraft {
  Future<String> persistenceRecord();
  Future<String?> takeSecret();
  void dispose();
}

Future<IntegrationApiKeyDraft> createIntegrationApiKeyDraft({required String name, required String grant, int? expiresAt}) async =>
    _RustApiKeyDraft(await rust.createIntegrationApiKey(name: name, grant: grant, expiresAt: expiresAt == null ? null : BigInt.from(expiresAt)));

Future<void> validateIntegrationApiSettings(String config) => rust.validateIntegrationApiConfiguration(config: config);

class _RustApiKeyDraft implements IntegrationApiKeyDraft {
  final rust.RsApiKeyDraft _draft;
  _RustApiKeyDraft(this._draft);
  @override
  Future<String> persistenceRecord() => _draft.record();
  @override
  Future<String?> takeSecret() => _draft.takeSecret();
  @override
  void dispose() => _draft.dispose();
  @override
  String toString() => 'IntegrationApiKeyDraft(redacted)';
}
