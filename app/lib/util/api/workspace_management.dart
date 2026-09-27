import 'dart:convert';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_isolates/util/workspace_password.dart';

final _workspaceId = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

Map<String, Object?> _descriptor(DirectoryWorkspace entry) => {
  'id': entry.id,
  'name': entry.name,
  'slug': entry.slug,
  'enabled': entry.enabled,
  'visible': entry.visible,
  'allowUpload': entry.allowUpload,
  'generation': entry.generation,
  'invalidReason': entry.invalidReason?.name,
  'passwordProtected': entry.passwordHash != null,
};

/// Executes a trusted host request, not a direct JSON-to-persistence bridge.
/// Server-provided workspace scope and claim are both required. No remote root,
/// arbitrary filesystem paths are accepted; credentials and source paths never
/// enter a returned descriptor or diagnostic.
Future<String> executeWorkspaceManagement({
  required WorkspaceCatalog catalog,
  required String request,
  required Future<bool> Function() claim,
  required Future<void> Function() publish,
  Future<String> Function(String) derivePassword = deriveWorkspacePassword,
}) async {
  String response(int status, Map<String, Object?> body) => jsonEncode({'status': status, 'body': body});
  Map<String, Object?> errorBody(String code) => {
    'error': {'code': code},
  };
  try {
    if (request.length > 16384) throw const FormatException();
    final data = jsonDecode(request);
    if (data is! Map<String, dynamic> ||
        data.keys.any(
          (key) => !{
            'operation',
            'workspaceId',
            'generation',
            'name',
            'visible',
            'allowUpload',
            'workspaces',
            'sourceId',
            'slug',
            'password',
            'clear',
          }.contains(key),
        )) {
      throw const FormatException();
    }
    final operation = data['operation'];
    final grants = data['workspaces'];
    if (operation is! String ||
        !{'list', 'update', 'enable', 'disable', 'validate', 'destroy', 'sources', 'create', 'configure', 'password'}.contains(operation) ||
        grants is! List ||
        grants.length > 256 ||
        grants.any((id) => id is! String || (id != '*' && _workspaceId.stringMatch(id) != id)) ||
        grants.toSet().length != grants.length ||
        (grants.contains('*') && grants.length != 1)) {
      throw const FormatException();
    }
    bool allowed(String id) => grants.contains('*') || grants.contains(id);
    if (operation == 'sources') {
      if (!grants.contains('*')) return response(404, errorBody('workspace_not_found'));
      if (data.keys.any((key) => !{'operation', 'workspaces'}.contains(key))) throw const FormatException();
      final sources = await catalog.managementSources(claim: claim);
      return response(200, {'sources': sources.map((source) => source.descriptor()).toList()});
    }
    if (operation == 'create') {
      if (!grants.contains('*')) return response(404, errorBody('workspace_not_found'));
      if (data.keys.any((key) => !{'operation', 'workspaces', 'sourceId', 'name', 'slug', 'visible', 'allowUpload'}.contains(key)) ||
          data['sourceId'] is! String ||
          _workspaceId.stringMatch(data['sourceId'] as String) != data['sourceId'] ||
          data['name'] is! String ||
          data['slug'] is! String ||
          data.containsKey('visible') && data['visible'] is! bool ||
          data.containsKey('allowUpload') && data['allowUpload'] is! bool) {
        throw const FormatException();
      }
      final entry = await catalog.managementCreate(
        sourceId: data['sourceId'] as String,
        name: data['name'] as String,
        slug: data['slug'] as String,
        visible: data['visible'] as bool? ?? true,
        allowUpload: data['allowUpload'] as bool? ?? false,
        claim: claim,
      );
      try {
        await publish();
      } catch (_) {
        return response(503, {...errorBody('config_saved_sync_pending'), 'workspace': _descriptor(entry)});
      }
      return response(200, {'workspace': _descriptor(entry)});
    }
    if (operation == 'list') {
      if (data.keys.any((key) => !{'operation', 'workspaces'}.contains(key))) throw const FormatException();
      final entries = await catalog.managementSnapshot(claim: claim);
      return response(200, {'workspaces': entries.where((entry) => allowed(entry.id)).map(_descriptor).toList()});
    }
    final id = data['workspaceId'];
    final generation = data['generation'];
    if (id is! String || _workspaceId.stringMatch(id) != id || generation is! int || generation < 1 || generation >= 0x1fffffffffffff) {
      throw const FormatException();
    }
    if (!allowed(id)) return response(404, errorBody('workspace_not_found'));
    if (operation == 'update') {
      if (!data.keys.any({'name', 'visible', 'allowUpload'}.contains)) throw const FormatException();
      if (data.containsKey('name') &&
          (data['name'] is! String ||
              (data['name'] as String).trim().isEmpty ||
              (data['name'] as String).trim().length > 120 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(data['name'] as String))) {
        throw const FormatException();
      }
      for (final flag in ['visible', 'allowUpload']) {
        if (data.containsKey(flag) && data[flag] is! bool) throw const FormatException();
      }
    } else if (data.keys.any({'name', 'visible', 'allowUpload'}.contains)) {
      throw const FormatException();
    }
    if (operation == 'configure') {
      if (!data.keys.any({'sourceId', 'slug'}.contains) || data.containsKey('password') || data.containsKey('clear')) throw const FormatException();
      if (data.containsKey('sourceId') && (data['sourceId'] is! String || _workspaceId.stringMatch(data['sourceId'] as String) != data['sourceId'])) {
        throw const FormatException();
      }
      if (data.containsKey('slug') && data['slug'] is! String) throw const FormatException();
    } else if (data.keys.any({'sourceId', 'slug'}.contains)) {
      throw const FormatException();
    }
    Future<String?> Function()? verifier;
    if (operation == 'password') {
      if (data['clear'] == true && !data.containsKey('password')) {
        verifier = () async => null;
      } else if (data['password'] is String && !data.containsKey('clear')) {
        final password = data['password'] as String;
        if (password.runes.length < 4 ||
            password.runes.length > 128 ||
            utf8.encode(password).length > 1024 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(password)) {
          throw const FormatException();
        }
        verifier = () => derivePassword(password);
      } else {
        throw const FormatException();
      }
    } else if (data.keys.any({'password', 'clear'}.contains)) {
      throw const FormatException();
    }
    final action = WorkspaceManagementAction.values.byName(operation);
    final entry = await catalog.manage(
      id: id,
      generation: generation,
      action: action,
      claim: claim,
      name: data['name'] as String?,
      visible: data['visible'] as bool?,
      allowUpload: data['allowUpload'] as bool?,
      sourceId: data['sourceId'] as String?,
      slug: data['slug'] as String?,
      passwordVerifier: verifier,
    );
    final body = operation == 'destroy' ? <String, Object?>{'destroyed': true, 'id': entry.id} : <String, Object?>{'workspace': _descriptor(entry)};
    try {
      // Persisted intent is not published state. The host must await its real
      // publication acknowledgement, including withdrawal of disabled routes.
      await publish();
    } catch (_) {
      return response(503, {...errorBody('config_saved_sync_pending'), ...body});
    }
    if ((operation == 'enable' || operation == 'validate') && entry.invalidReason != null) {
      return response(422, {...errorBody('workspace_invalid'), ...body});
    }
    return response(200, body);
  } on WorkspaceManagementException catch (error) {
    return switch (error.failure) {
      WorkspaceManagementFailure.notFound => response(404, errorBody('workspace_not_found')),
      WorkspaceManagementFailure.staleGeneration => response(409, errorBody('stale_generation')),
      WorkspaceManagementFailure.sourceNotApproved => response(404, errorBody('source_not_approved')),
      WorkspaceManagementFailure.mustBeClosed => response(409, errorBody('workspace_must_be_closed')),
      WorkspaceManagementFailure.claimRejected => response(503, errorBody('management_claim_rejected')),
    };
  } on WorkspaceCatalogException catch (error) {
    return response(503, errorBody('catalog_${error.failure.name}_failed'));
  } on FormatException {
    return response(400, errorBody('invalid_management_request'));
  } catch (_) {
    return response(503, errorBody('workspace_management_unavailable'));
  }
}
