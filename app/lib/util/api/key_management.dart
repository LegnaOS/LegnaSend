import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/util/api/api_settings.dart';

class ApiKeyManagementException implements Exception {
  final int status;
  final String code;
  const ApiKeyManagementException(this.status, this.code);
}

Map<String, Object?> apiKeyMetadataJson(ApiKeyMetadata key) => {
  'id': key.id,
  'name': key.name,
  'grant': key.grant.toJson(),
  'createdAt': key.createdAt,
  'expiresAt': key.expiresAt,
  'enabled': key.enabled,
  'limits': key.limits?.toJson(),
};

bool apiGrantContains(ApiGrant parent, ApiGrant child) =>
    child.scopes.every(parent.scopes.contains) && child.workspaces.every((id) => parent.workspaces.contains('*') || parent.workspaces.contains(id));

String apiKeySetVersion(ApiSettings settings) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'keys': settings.keys.map(apiKeyMetadataJson).toList(),
          'receipts': settings.keyReceipts,
        }),
      ),
    )
    .toString();

/// Durable receipts have no token, verifier, native path or credential fragment.
/// The request digest binds semantic inputs and caller identity; replay never
/// returns the first delivery's one-time secret and never creates another key.
Map<String, Object?> apiKeyReceipt({
  required String principal,
  required String requestId,
  required String digest,
  required String action,
  required String keyId,
  required int createdAt,
}) => {
  'principal': principal,
  'requestId': requestId,
  'digest': digest,
  'action': action,
  'keyId': keyId,
  'createdAt': createdAt,
};

void validateApiKeyReceipts(List<Map<String, Object?>> receipts) {
  if (receipts.length > 256) throw const FormatException('Too many key receipts');
  final seen = <String>{};
  for (final receipt in receipts) {
    if (receipt.keys.toSet().difference({'principal', 'requestId', 'digest', 'action', 'keyId', 'createdAt'}).isNotEmpty ||
        receipt.length != 6 ||
        !['create', 'pause', 'resume', 'revoke'].contains(receipt['action']) ||
        receipt['createdAt'] is! int ||
        (receipt['createdAt'] as int) < 0) {
      throw const FormatException('Invalid key receipt');
    }
    for (final field in ['principal', 'requestId', 'keyId']) {
      if (receipt[field] is! String ||
          !RegExp(r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$').hasMatch(receipt[field] as String)) {
        throw const FormatException('Invalid key receipt identity');
      }
    }
    if (receipt['digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt['digest'] as String) ||
        !seen.add('${receipt['principal']}:${receipt['requestId']}')) {
      throw const FormatException('Invalid key receipt digest');
    }
  }
}
