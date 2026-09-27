import 'dart:convert';

import 'package:localsend_app/util/api/key_management.dart' show validateApiKeyReceipts;

/// Public metadata is intentionally separate from verifier-bearing persistence.
/// These codecs reject unknown fields instead of silently keeping future credentials.
enum ApiScope {
  service('service.read'),
  workspaces('workspaces.read'),
  files('files.read'),
  upload('files.upload'),
  manage('workspaces.manage'),
  requests('requests.read'),
  devicesRead('devices.read'),
  devicesScan('devices.scan'),
  transfersRead('transfers.read'),
  transfersSend('transfers.send'),
  transfersControl('transfers.control'),
  cacheRead('cache.read'),
  cacheClean('cache.clean'),
  settingsRead('settings.read'),
  settingsWrite('settings.write'),
  keysManage('keys.manage'),
  nativeTasksRead('nativeTasks.read'),
  nativeTasksControl('nativeTasks.control'),
  requestsManage('requests.manage')
  ;

  final String wire;
  const ApiScope(this.wire);
  bool get requiresGlobal =>
      wire.startsWith('nativeTasks.') ||
      wire.startsWith('devices.') ||
      wire.startsWith('transfers.') ||
      wire.startsWith('cache.') ||
      wire.startsWith('settings.') ||
      wire == 'keys.manage' ||
      wire == 'requests.manage';
  bool get allowsAnonymous => [ApiScope.service, ApiScope.workspaces, ApiScope.files].contains(this);
}

class ApiLimits {
  final int perSecond;
  final int perMinute;
  final int concurrent;
  const ApiLimits(this.perSecond, this.perMinute, this.concurrent);
  void validate() {
    if (perSecond < 0 || perSecond > 1000 || perMinute < 0 || perMinute > 60000 || concurrent < 0 || concurrent > 64) {
      throw const FormatException('Invalid API limits');
    }
  }

  Map<String, dynamic> toJson() => {'perSecond': perSecond, 'perMinute': perMinute, 'concurrent': concurrent};
  factory ApiLimits.fromJson(Object? value) {
    final data = _map(value, {'perSecond', 'perMinute', 'concurrent'});
    final result = ApiLimits(_integer(data['perSecond']), _integer(data['perMinute']), _integer(data['concurrent']));
    result.validate();
    return result;
  }
}

class ApiGrant {
  final List<ApiScope> scopes;
  final List<String> workspaces;
  ApiGrant({required Iterable<ApiScope> scopes, required Iterable<String> workspaces})
    : scopes = List.unmodifiable(scopes),
      workspaces = List.unmodifiable(workspaces) {
    if (this.scopes.toSet().length != this.scopes.length ||
        this.workspaces.length > 256 ||
        this.workspaces.toSet().length != this.workspaces.length ||
        this.workspaces.any((id) => id != '*' && !_uuid.hasMatch(id)) ||
        (this.workspaces.contains('*') && this.workspaces.length != 1)) {
      throw const FormatException('Invalid API grant');
    }
  }
  Map<String, dynamic> toJson() => {'scopes': scopes.map((s) => s.wire).toList(), 'workspaces': workspaces};
  factory ApiGrant.fromJson(Object? value) {
    final data = _map(value, {'scopes', 'workspaces'});
    return ApiGrant(
      scopes: _strings(
        data['scopes'],
      ).map((s) => ApiScope.values.firstWhere((v) => v.wire == s, orElse: () => throw const FormatException('Invalid API scope'))),
      workspaces: _strings(data['workspaces']),
    );
  }
}

class ApiPolicy {
  final bool enabled;
  final bool authRequired;
  final ApiLimits globalLimits;
  final ApiLimits keyLimits;
  final ApiLimits anonymousLimits;
  final ApiGrant anonymousGrant;
  final List<String> allowedOrigins;
  ApiPolicy({
    this.enabled = false,
    this.authRequired = true,
    this.globalLimits = const ApiLimits(30, 600, 16),
    this.keyLimits = const ApiLimits(10, 300, 4),
    this.anonymousLimits = const ApiLimits(5, 60, 2),
    ApiGrant? anonymousGrant,
    Iterable<String> allowedOrigins = const [],
  }) : anonymousGrant = anonymousGrant ?? ApiGrant(scopes: [ApiScope.service, ApiScope.workspaces, ApiScope.files], workspaces: ['*']),
       allowedOrigins = List.unmodifiable(allowedOrigins) {
    globalLimits.validate();
    keyLimits.validate();
    anonymousLimits.validate();
    if (this.anonymousGrant.scopes.any((s) => !s.allowsAnonymous) || this.allowedOrigins.length > 16) {
      throw const FormatException('Invalid anonymous or origin policy');
    }
    for (final origin in this.allowedOrigins) {
      final uri = Uri.tryParse(origin);
      if (origin.length > 512 ||
          uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          origin != uri.origin ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Invalid API origin');
      }
    }
  }
  ApiPolicy copyWith({
    bool? enabled,
    bool? authRequired,
    ApiLimits? globalLimits,
    ApiLimits? keyLimits,
    ApiLimits? anonymousLimits,
    ApiGrant? anonymousGrant,
    Iterable<String>? allowedOrigins,
  }) => ApiPolicy(
    enabled: enabled ?? this.enabled,
    authRequired: authRequired ?? this.authRequired,
    globalLimits: globalLimits ?? this.globalLimits,
    keyLimits: keyLimits ?? this.keyLimits,
    anonymousLimits: anonymousLimits ?? this.anonymousLimits,
    anonymousGrant: anonymousGrant ?? this.anonymousGrant,
    allowedOrigins: allowedOrigins ?? this.allowedOrigins,
  );
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'authRequired': authRequired,
    'globalLimits': globalLimits.toJson(),
    'keyLimits': keyLimits.toJson(),
    'anonymousLimits': anonymousLimits.toJson(),
    'anonymousGrant': anonymousGrant.toJson(),
    'allowedOrigins': allowedOrigins,
  };
  factory ApiPolicy.fromJson(Object? value) {
    final data = _map(value, _policyFields);
    return ApiPolicy(
      enabled: _boolean(data['enabled']),
      authRequired: _boolean(data['authRequired']),
      globalLimits: ApiLimits.fromJson(data['globalLimits']),
      keyLimits: ApiLimits.fromJson(data['keyLimits']),
      anonymousLimits: ApiLimits.fromJson(data['anonymousLimits']),
      anonymousGrant: ApiGrant.fromJson(data['anonymousGrant']),
      allowedOrigins: _strings(data['allowedOrigins']),
    );
  }
}

bool isApiKeyNameValid(String value) => value.trim().isNotEmpty && utf8.encode(value).length <= 256 && !_controls.hasMatch(value);

class ApiKeyMetadata {
  final String id;
  final String name;
  final ApiGrant grant;
  final int createdAt;
  final int? expiresAt;
  final bool enabled;
  final ApiLimits? limits;
  const ApiKeyMetadata({
    required this.id,
    required this.name,
    required this.grant,
    required this.createdAt,
    required this.expiresAt,
    this.enabled = true,
    this.limits,
  });
  bool get expired => expiresAt != null && expiresAt! <= DateTime.now().millisecondsSinceEpoch ~/ 1000;
  @override
  String toString() => 'ApiKeyMetadata($id)';
}

class _ApiKeyRecord {
  final ApiKeyMetadata metadata;
  final String verifier;
  _ApiKeyRecord(this.metadata, this.verifier);
  factory _ApiKeyRecord.fromJson(Object? value) {
    final data = _map(value, {'id', 'name', 'grant', 'createdAt', 'expiresAt', 'verifier'}, optional: {'enabled', 'limits'});
    final id = _string(data['id']);
    final name = _string(data['name']);
    final verifier = _string(data['verifier']);
    final created = _integer(data['createdAt']);
    final expires = data['expiresAt'] == null ? null : _integer(data['expiresAt']);
    if (!_uuid.hasMatch(id) ||
        name.trim().isEmpty ||
        utf8.encode(name).length > 256 ||
        _controls.hasMatch(name) ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(verifier) ||
        created < 0 ||
        created > 253402300799 ||
        (expires != null && (expires < 0 || expires > 253402300799))) {
      throw const FormatException('Invalid API key record');
    }
    return _ApiKeyRecord(
      ApiKeyMetadata(
        id: id,
        name: name,
        grant: ApiGrant.fromJson(data['grant']),
        createdAt: created,
        expiresAt: expires,
        enabled: data.containsKey('enabled') ? _boolean(data['enabled']) : true,
        limits: data['limits'] == null ? null : ApiLimits.fromJson(data['limits']),
      ),
      verifier,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': metadata.id,
    'name': metadata.name,
    'grant': metadata.grant.toJson(),
    'createdAt': metadata.createdAt,
    'expiresAt': metadata.expiresAt,
    'verifier': verifier,
    'enabled': metadata.enabled,
    'limits': metadata.limits?.toJson(),
  };
  @override
  String toString() => 'ApiKeyRecord(${metadata.id}, redacted)';
}

/// Keep this object private to the settings owner, never in provider state.
class ApiSettings {
  static const maxBytes = 512 * 1024;
  final ApiPolicy policy;
  final List<_ApiKeyRecord> _records;
  final List<Map<String, Object?>> keyReceipts;
  ApiSettings._(this.policy, Iterable<_ApiKeyRecord> records, [List<Map<String, Object?>> receipts = const []])
    : _records = List.unmodifiable(records),
      keyReceipts = List.unmodifiable(receipts.map((value) => Map<String, Object?>.unmodifiable(value))) {
    validateApiKeyReceipts(keyReceipts);
    if (_records.length > 128 || _records.map((k) => k.metadata.id).toSet().length != _records.length) {
      throw const FormatException('Invalid API key set');
    }
  }
  factory ApiSettings.defaults() => ApiSettings._(ApiPolicy(), []);
  List<ApiKeyMetadata> get keys => List.unmodifiable(_records.map((record) => record.metadata));
  ApiSettings withPolicy(ApiPolicy policy) => ApiSettings._(policy, _records, keyReceipts);
  ApiSettings addRecord(String raw) {
    if (utf8.encode(raw).length > maxBytes) throw const FormatException('API key record too large');
    return ApiSettings._(policy, [..._records, _ApiKeyRecord.fromJson(_decode(raw))], keyReceipts);
  }

  ApiSettings revoke(String id) => ApiSettings._(policy, _records.where((r) => r.metadata.id != id), keyReceipts);
  ApiSettings rename(String id, String name) =>
      ApiSettings._(policy, _records.map((r) => r.metadata.id == id ? _ApiKeyRecord.fromJson({...r.toJson(), 'name': name}) : r), keyReceipts);
  ApiSettings setEnabled(String id, bool enabled) =>
      ApiSettings._(policy, _records.map((r) => r.metadata.id == id ? _ApiKeyRecord.fromJson({...r.toJson(), 'enabled': enabled}) : r), keyReceipts);
  ApiSettings setKeyLimits(String id, ApiLimits? limits) {
    limits?.validate();
    return ApiSettings._(
      policy,
      _records.map((r) => r.metadata.id == id ? _ApiKeyRecord.fromJson({...r.toJson(), 'limits': limits?.toJson()}) : r),
      keyReceipts,
    );
  }

  Map<String, dynamic> _json() => {...policy.toJson(), 'keys': _records.map((r) => r.toJson()).toList()};
  ApiSettings withKeyReceipt(Map<String, Object?> receipt) => ApiSettings._(policy, _records, [...keyReceipts, receipt]);
  String encode() => _bounded(jsonEncode({'version': 2, 'settings': _json(), if (keyReceipts.isNotEmpty) 'keyReceipts': keyReceipts}));
  String configuration(int revision) => _bounded(jsonEncode({'revision': revision, ..._json()}));
  factory ApiSettings.decode(String? raw) {
    if (raw == null) return ApiSettings.defaults();
    _bounded(raw);
    final envelope = _map(_decode(raw), {'version', 'settings'}, optional: {'keyReceipts'});
    if (envelope['version'] != 1 && envelope['version'] != 2) throw const FormatException('Unsupported API settings version');
    final data = _map(envelope['settings'], {..._policyFields, 'keys'});
    final records = data.remove('keys');
    if (records is! List) throw const FormatException('Invalid API key list');
    final receipts = envelope['keyReceipts'] ?? [];
    if (receipts is! List || receipts.any((value) => value is! Map<String, dynamic>)) throw const FormatException('Invalid key receipts');
    return ApiSettings._(ApiPolicy.fromJson(data), records.map(_ApiKeyRecord.fromJson), [
      for (final value in receipts) Map<String, Object?>.from(value as Map),
    ]);
  }
  @override
  String toString() => 'ApiSettings(enabled: ${policy.enabled}, keys: ${_records.length}, redacted)';
}

const _policyFields = {'enabled', 'authRequired', 'globalLimits', 'keyLimits', 'anonymousLimits', 'anonymousGrant', 'allowedOrigins'};
final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
String _bounded(String value) {
  if (utf8.encode(value).length > ApiSettings.maxBytes) throw const FormatException('API settings too large');
  return value;
}

Object? _decode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    throw const FormatException('Invalid API settings');
  }
}

Map<String, dynamic> _map(Object? value, Set<String> fields, {Set<String> optional = const {}}) {
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference({...fields, ...optional}).isNotEmpty ||
      fields.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid API settings fields');
  }
  return Map.of(value);
}

String _string(Object? value) => value is String ? value : throw const FormatException('Invalid API string');
int _integer(Object? value) => value is int ? value : throw const FormatException('Invalid API integer');
bool _boolean(Object? value) => value is bool ? value : throw const FormatException('Invalid API switch');
List<String> _strings(Object? value) {
  if (value is! List || value.any((v) => v is! String)) throw const FormatException('Invalid API list');
  return value.cast<String>();
}
