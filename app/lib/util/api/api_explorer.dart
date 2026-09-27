import 'dart:convert';

class ApiParameter {
  final String name;
  final String location;
  final bool required;
  final Map<String, dynamic> schema;
  final String description;
  ApiParameter(Map<String, dynamic> value)
    : name = value['name'] as String,
      location = value['in'] as String,
      required = value['required'] == true,
      schema = Map.unmodifiable(value['schema'] as Map<String, dynamic>? ?? {}),
      description = (value['description'] ?? (value['schema'] as Map?)?['description']) as String? ?? '';
  // Schema length counts Unicode scalar values, not UTF-16 code units or UI
  // grapheme clusters. The wire budget is separate and remains byte bounded.
  int get inputLimit {
    final declared = schema['maxLength'];
    return declared is int && declared >= 0 ? declared.clamp(0, 8192) : 4096;
  }

  int get utf8Limit {
    final declared = schema['x-legnasend-max-utf8-bytes'];
    return declared is int && declared >= 0 ? declared.clamp(0, 8192) : 4096;
  }

  bool valid(String value) {
    if (value.isEmpty) return !required;
    if (utf8.encode(value).length > utf8Limit || RegExp(r'[\x00-\x1f\x7f\x80-\x9f]').hasMatch(value)) return false;
    if (value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) return false;
    final characters = value.runes.length;
    if (characters > inputLimit) return false;
    if (schema['minLength'] case final int minimum) {
      if (characters < minimum) return false;
    }
    if (schema['pattern'] case final String pattern) {
      try {
        if (!RegExp(pattern, unicode: true).hasMatch(value)) return false;
      } on FormatException {
        return false;
      }
    }
    if (schema['enum'] case final List values) {
      if (!values.any((v) => v.toString() == value)) return false;
    }
    if (schema['format'] == 'uuid' && !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(value)) {
      return false;
    }
    if (schema['type'] == 'boolean' && value != 'true' && value != 'false') return false;
    if (schema['type'] == 'integer') {
      if (!RegExp(r'^\d+$').hasMatch(value)) return false;
      final number = BigInt.tryParse(value);
      if (number == null) return false;
      if (schema['minimum'] case final num min) {
        if (number < BigInt.from(min)) return false;
      }
      if (schema['maximum'] case final num max) {
        if (number > BigInt.from(max)) return false;
      }
    }
    return true;
  }
}

class ApiOperation {
  final String path;
  final String method;
  final String id;
  final String summary;
  final String description;
  final List<ApiParameter> parameters;
  final Map<String, dynamic> responses;
  final int maxQueryBytes;
  ApiOperation(this.path, this.method, Map<String, dynamic> value)
    : id = value['operationId'] as String,
      summary = value['summary'] as String? ?? '',
      description = value['description'] as String? ?? '',
      parameters = List.unmodifiable((value['parameters'] as List? ?? []).map((p) => ApiParameter(Map<String, dynamic>.from(p)))),
      responses = Map.unmodifiable(value['responses'] as Map<String, dynamic>? ?? {}),
      maxQueryBytes = (value['x-legnasend-max-query-bytes'] as int? ?? 8192).clamp(0, 24 * 1024);
  bool get isNativeTask => ['listNativeTasks', 'controlNativeTask', 'listSourceEndNotices', 'retrySourceEndNotice'].contains(id);
  bool get isSourceEndRetry => id == 'retrySourceEndNotice';
  bool get isNativeTaskMutation => id == 'controlNativeTask' || isSourceEndRetry;
  bool get isWorkspaceSend => id == 'sendWorkspaceFiles';
  bool get isKeys => ['listKeys', 'createKey', 'manageKey', 'getKeyReceipt'].contains(id);
  bool get isKeyMutation => isKeys && method == 'POST';
  bool get isHistoryControl => id == 'clearRequests';
  bool get isHost => ['inspectCache', 'cleanupCache', 'readSettings', 'updateSettings'].contains(id);
  bool get isHostMutation => isHost && method == 'POST';
  bool get isManagement => ['manageWorkspace', 'createWorkspace'].contains(id) && method == 'POST';
  bool get isCreate => id == 'createWorkspace';
  bool get isTransfer => [
    'listDevices',
    'getDevice',
    'scanDevices',
    'getSendSelection',
    'sendSelection',
    'sendWorkspaceFiles',
    'listTransfers',
    'getTransfer',
    'cancelTransfer',
    'retryTransfer',
    'removeTransfer',
  ].contains(id);
  bool get isTransferMutation => isTransfer && method == 'POST';
  bool get hasRequestId => id == 'sendSelection' || isWorkspaceSend || id == 'retryTransfer' || isKeyMutation || isSourceEndRetry;
  bool get isArchiveSelection => ['prepareWorkspaceArchive', 'cancelWorkspaceArchive'].contains(id);
  bool get isPreviewLease => ['prepareDocumentPreview', 'closeDocumentPreview'].contains(id);
  bool get isMutation =>
      isArchiveSelection ||
      isPreviewLease ||
      isNativeTaskMutation ||
      isKeyMutation ||
      isHistoryControl ||
      isUpload ||
      isManagement ||
      isTransferMutation ||
      isHostMutation;
  bool get isUpload => id == 'uploadFile' && method == 'POST';
  // Upload framing is derived from the selected source, never editable input.
  Iterable<ApiParameter> get inputParameters => parameters.where(
    (p) => !(isUpload && p.location == 'header' && p.name.toLowerCase() == 'content-length'),
  );
  String get group => isTransfer || isNativeTask
      ? 'transfers'
      : path.startsWith('/requests')
      ? 'history'
      : path.contains('/files')
      ? 'files'
      : path.startsWith('/workspaces') || path.startsWith('/managed-workspaces') || path == '/approved-workspace-sources'
      ? 'workspaces'
      : 'service';
  bool matches(String query) => '$method $path $id $summary $description'.toLowerCase().contains(query.toLowerCase());
  List<String> bodyFields(Map<String, String> values) => isArchiveSelection
      ? (id == 'prepareWorkspaceArchive' ? ['path', 'ids'] : ['selection'])
      : isPreviewLease
      ? [id == 'prepareDocumentPreview' ? 'id' : 'lease']
      : isNativeTaskMutation
      ? (isSourceEndRetry ? ['version', 'requestId'] : ['epoch', 'version', 'action'])
      : isWorkspaceSend
      ? ['instanceId', 'generation', 'deviceId', 'channelId', 'localRouteId', 'requestId', 'sourceMode', 'files']
      : isHistoryControl
      ? ['instanceId', 'expectedGeneration', 'throughSequence']
      : id == 'createKey'
      ? ['version', 'requestId', 'name', 'scopes', 'workspaces', 'expiresAt']
      : id == 'manageKey'
      ? ['version', 'requestId', 'action']
      : id == 'updateSettings'
      ? ['version', 'field', 'value']
      : id == 'sendSelection'
      ? ['deviceId', 'selectionVersion', 'requestId', 'channelId', 'localRouteId']
      : id == 'retryTransfer'
      ? ['requestId']
      : isCreate
      ? ['sourceId', 'name', 'slug', 'visible', 'allowUpload']
      : isManagement && values['action'] == 'configure'
      ? ['sourceId', 'slug']
      : isManagement && values['action'] == 'password'
      ? ['password', 'clear']
      : const [];
  Map<String, Object>? body(Map<String, String> values, {bool placeholders = false}) {
    if (bodyFields(values).isEmpty) return null;
    if (isArchiveSelection) {
      if (id == 'cancelWorkspaceArchive') return {'selection': placeholders ? 'SELECTION_UUID' : values['body.selection'] ?? ''};
      Object ids;
      try {
        ids = jsonDecode(values['body.ids'] ?? '[]') as Object;
      } catch (_) {
        ids = <Object>[];
      }
      return {
        'path': placeholders ? 'PARENT_DIRECTORY' : values['body.path'] ?? '',
        'ids': placeholders ? ['FILE_ID'] : ids,
      };
    }
    if (isNativeTaskMutation) {
      return {
        for (final field in bodyFields(values)) field: placeholders && field != 'action' ? field.toUpperCase() : values['body.$field'] ?? '',
      };
    }
    if (isWorkspaceSend) {
      Object files;
      try {
        files = jsonDecode(values['body.files'] ?? '[]') as Object;
      } catch (_) {
        files = <Object>[];
      }
      return {
        'instanceId': placeholders ? 'INSTANCE_ID' : values['body.instanceId'] ?? '',
        'generation': int.tryParse(values['body.generation'] ?? '') ?? 0,
        'deviceId': placeholders ? 'DEVICE_ID' : values['body.deviceId'] ?? '',
        if ((values['body.channelId'] ?? '').isNotEmpty) 'channelId': placeholders ? 'CHANNEL_ID' : values['body.channelId']!,
        if ((values['body.localRouteId'] ?? '').isNotEmpty) 'localRouteId': placeholders ? 'LOCAL_ROUTE_ID' : values['body.localRouteId']!,
        'requestId': placeholders ? 'REQUEST_ID' : values['body.requestId'] ?? '',
        if ((values['body.sourceMode'] ?? '').isNotEmpty) 'sourceMode': values['body.sourceMode']!,
        'files': placeholders
            ? [
                {'id': 'FILE_ID', if (values['body.sourceMode'] != 'documentSnapshot') 'version': '"ETAG"'},
              ]
            : files,
      };
    }
    if (isHistoryControl) {
      return {
        'instanceId': values['body.instanceId'] ?? '',
        'expectedGeneration': int.tryParse(values['body.expectedGeneration'] ?? '') ?? -1,
        'throughSequence': int.tryParse(values['body.throughSequence'] ?? '') ?? -1,
      };
    }
    if (isKeyMutation) {
      final result = <String, Object>{
        'version': placeholders ? 'KEYS_VERSION' : values['body.version'] ?? '',
        'requestId': placeholders ? 'REQUEST_ID' : values['body.requestId'] ?? '',
      };
      if (id == 'manageKey') return {...result, 'action': values['body.action'] ?? ''};
      return {
        ...result, 'name': placeholders ? 'KEY_NAME' : values['body.name'] ?? '',
        'grant': {
          'scopes': (values['body.scopes'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
          'workspaces': (values['body.workspaces'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        },
        // Nullable expiry is encoded explicitly by request(), not a secret.
        'expiresAt': values['body.expiresAt']?.isNotEmpty == true ? int.tryParse(values['body.expiresAt']!) ?? -1 : 0,
      };
    }
    if (id == 'updateSettings') {
      final field = values['body.field'] ?? '';
      final value = values['body.value'] ?? '';
      return {
        'version': placeholders ? 'SETTINGS_VERSION' : values['body.version'] ?? '',
        'field': field,
        'value': field == 'receiveCacheRetentionDays'
            ? int.tryParse(value) ?? value
            : ['enableAnimations', 'autoFinish', 'createChecksums', 'verifyChecksums'].contains(field)
            ? value == 'true'
            : value,
      };
    }
    if (hasRequestId) {
      return {
        for (final field in bodyFields(values))
          if ((values['body.$field'] ?? '').isNotEmpty)
            field: placeholders
                ? {
                    'deviceId': 'DEVICE_ID',
                    'selectionVersion': 'SELECTION_VERSION',
                    'requestId': 'REQUEST_ID',
                    'channelId': 'CHANNEL_ID',
                    'localRouteId': 'LOCAL_ROUTE_ID',
                  }[field]!
                : values['body.$field']!,
      };
    }
    if (values['action'] == 'password') {
      if (values['body.clear'] == 'true') return {'clear': true};
      return {'password': placeholders ? 'PASSWORD' : values['body.password'] ?? ''};
    }
    return {
      for (final field in bodyFields(values))
        if ((values['body.$field'] ?? '').isNotEmpty)
          field: ['visible', 'allowUpload'].contains(field)
              ? values['body.$field'] == 'true'
              : placeholders
              ? (field == 'sourceId'
                    ? 'SOURCE_ID'
                    : field == 'slug'
                    ? 'workspace-name'
                    : 'WORKSPACE_NAME')
              : values['body.$field']!,
    };
  }

  bool _validBody(Map<String, String> values) {
    final payload = body(values);
    if (payload == null) return true;
    if (isArchiveSelection) {
      if (id == 'cancelWorkspaceArchive') {
        return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(values['body.selection'] ?? '');
      }
      final path = payload['path'] as String;
      final ids = payload['ids'];
      final seen = <String>{};
      if (utf8.encode(path).length > 4096 ||
          path.contains('\x00') ||
          path.runes.any((r) => r >= 0xd800 && r <= 0xdfff) ||
          utf8.encode(jsonEncode(payload)).length > 2 * 1024 * 1024) {
        return false;
      }
      return ids is List &&
          ids.isNotEmpty &&
          ids.length <= 20000 &&
          ids.every(
            (item) =>
                item is String &&
                item.isNotEmpty &&
                utf8.encode(item).length <= 4096 &&
                !item.runes.any((r) => r >= 0xd800 && r <= 0xdfff) &&
                !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(item) &&
                seen.add(item),
          );
    }
    if (isPreviewLease) {
      final field = id == 'prepareDocumentPreview' ? 'id' : 'lease';
      return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(values['body.$field'] ?? '');
    }
    if (isNativeTaskMutation) {
      final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      return isSourceEndRetry
          ? ['version', 'requestId'].every((k) => uuid.hasMatch(values['body.$k'] ?? ''))
          : ['epoch', 'version'].every((k) => uuid.hasMatch(values['body.$k'] ?? '')) &&
                ['cancel', 'accept', 'reject', 'remove'].contains(values['body.action']);
    }
    if (isWorkspaceSend) {
      final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      if (!['instanceId', 'deviceId', 'requestId'].every((k) => uuid.hasMatch(payload[k] as String)) ||
          payload.containsKey('channelId') && !uuid.hasMatch(payload['channelId'] as String) ||
          payload.containsKey('localRouteId') && !uuid.hasMatch(payload['localRouteId'] as String) ||
          (payload['generation'] as int) < 1 ||
          utf8.encode(jsonEncode(payload)).length > 65536) {
        return false;
      }
      final mode = values['body.sourceMode'] ?? '';
      if (mode.isNotEmpty && mode != 'documentSnapshot') return false;
      final documents = mode == 'documentSnapshot';
      final files = payload['files'];
      if (files is! List || files.isEmpty || files.length > 128) return false;
      final ids = <String>{};
      return files.every(
        (f) =>
            f is Map &&
            f.length == (documents ? 1 : 2) &&
            f['id'] is String &&
            (documents
                ? RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(f['id'] as String)
                : RegExp(r'^[A-Za-z0-9_-]{1,4096}$').hasMatch(f['id'] as String)) &&
            ids.add(f['id'] as String) &&
            (documents || f['version'] is String && RegExp(r'^"[A-Za-z0-9_.-]{1,254}"$').hasMatch(f['version'] as String)),
      );
    }
    if (id == 'updateSettings') {
      final field = values['body.field'], value = values['body.value'] ?? '';
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(values['body.version'] ?? '')) return false;
      if (['enableAnimations', 'autoFinish', 'createChecksums', 'verifyChecksums'].contains(field)) return ['true', 'false'].contains(value);
      if (field == 'receiveCacheRetentionDays') {
        final days = int.tryParse(value);
        return RegExp(r'^-?(0|[1-9][0-9]*)$').hasMatch(value) && days != null && days >= -2 && days <= 3650;
      }
      if (field == 'theme') return ['system', 'light', 'dark'].contains(value);
      if (field == 'locale') return RegExp(r'^[A-Za-z0-9-]{1,32}$').hasMatch(value);
      return field == 'alias' && value.trim().isNotEmpty && value.length <= 120 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
    }
    if (isKeyMutation) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(values['body.version'] ?? '') ||
          !RegExp(r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$').hasMatch(values['body.requestId'] ?? '')) {
        return false;
      }
      if (id == 'manageKey') return ['pause', 'resume', 'revoke'].contains(values['body.action']);
      return (values['body.name'] ?? '').trim().isNotEmpty &&
          (values['body.scopes'] ?? '').trim().isNotEmpty &&
          (values['body.workspaces'] ?? '').trim().isNotEmpty &&
          ((values['body.expiresAt'] ?? '').isEmpty || (int.tryParse(values['body.expiresAt']!) ?? -1) > 0);
    }
    if (isHistoryControl) {
      return RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(values['body.instanceId'] ?? '') &&
          (int.tryParse(values['body.expectedGeneration'] ?? '') ?? -1) > 0 &&
          (int.tryParse(values['body.throughSequence'] ?? '') ?? -1) >= 0;
    }
    final uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    if (hasRequestId) {
      if (payload.containsKey('localRouteId') &&
          !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(payload['localRouteId'] as String)) {
        return false;
      }
      final required = id == 'sendSelection' ? ['deviceId', 'selectionVersion', 'requestId'] : ['requestId'];
      return required.every(payload.containsKey) && payload.values.every((v) => v is String && uuid.stringMatch(v) == v);
    }
    if (values['action'] == 'password') {
      if (payload['clear'] == true) return (values['body.password'] ?? '').isEmpty;
      final password = payload['password'] as String;
      return password.runes.length >= 4 &&
          password.runes.length <= 128 &&
          utf8.encode(password).length <= 1024 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(password);
    }
    if (isCreate && ['sourceId', 'name', 'slug'].any((key) => !payload.containsKey(key))) return false;
    if (payload.isEmpty) return false;
    if (payload['sourceId'] case final String source) {
      if (uuid.stringMatch(source) != source) return false;
    }
    if (payload['slug'] case final String slug) {
      if (!RegExp(r'^[a-z][a-z0-9-]{0,47}$').hasMatch(slug) || slug.endsWith('-')) return false;
    }
    if (payload['name'] case final String name) {
      if (name.trim().isEmpty || name.trim().length > 120 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) return false;
    }
    return ['visible', 'allowUpload'].every((key) => !values.containsKey('body.$key') || ['', 'true', 'false'].contains(values['body.$key']));
  }

  bool valid(Map<String, String> values) {
    if (['downloadWorkspaceArchive', 'headWorkspaceArchive'].contains(id) &&
        (values['selection'] ?? '').isNotEmpty &&
        ((values['path'] ?? '').isNotEmpty || (values['ids'] ?? '').isNotEmpty)) {
      return false;
    }
    if (['downloadWorkspaceArchive', 'headWorkspaceArchive'].contains(id) && (values['ids'] ?? '').isNotEmpty) {
      try {
        final ids = jsonDecode(values['ids']!);
        final seen = <String>{};
        if (ids is! List ||
            ids.isEmpty ||
            ids.length > 128 ||
            !ids.every((entry) => entry is String && RegExp(r'^[A-Za-z0-9_-]{1,4096}$').hasMatch(entry) && seen.add(entry))) {
          return false;
        }
      } on FormatException {
        return false;
      }
    }
    if (!inputParameters.every((p) => p.valid(values[p.name] ?? '')) || !_validBody(values)) return false;
    final query = Uri(
      queryParameters: {
        for (final p in parameters)
          if (p.location == 'query' && (values[p.name] ?? '').isNotEmpty) p.name: values[p.name]!,
      },
    ).query;
    // Dart URI rendering and Rust form encoding differ for '~' and '*'. Bound
    // both representations so the console and copied examples both fit.
    int formLength(String text) => utf8
        .encode(text)
        .fold(
          0,
          (sum, byte) =>
              sum +
              (byte == 32 || byte >= 48 && byte <= 57 || byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || [45, 46, 95, 42].contains(byte)
                  ? 1
                  : 3),
        );
    var formBytes = 0;
    for (final p in parameters) {
      final value = values[p.name] ?? '';
      if (p.location != 'query' || value.isEmpty) continue;
      if (formBytes > 0) formBytes++;
      formBytes += formLength(p.name) + 1 + formLength(value);
    }
    if (query.length > maxQueryBytes || formBytes > maxQueryBytes) return false;
    if (!isManagement || isCreate) return true;
    final changes = ['name', 'visible', 'allowUpload'].where((key) => (values[key] ?? '').isNotEmpty).toList();
    if (values['action'] != 'update') return changes.isEmpty;
    if (changes.isEmpty) return false;
    final name = values['name'];
    return name == null || name.isEmpty || name.trim().isNotEmpty && utf8.encode(name).length <= 480;
  }

  Map<String, String> defaults() => {
    for (final p in parameters)
      if (p.schema['default'] != null && !(isManagement && ['visible', 'allowUpload'].contains(p.name))) p.name: p.schema['default'].toString(),
  };
  String request(Map<String, String> values, String token, {Map<String, Object>? uploadSource}) {
    if (!valid(values)) throw const FormatException('Invalid API parameters');
    if (isUpload && values['directory'] != 'true' && uploadSource == null) throw const FormatException('Choose an upload file');
    return jsonEncode({
      if (isUpload && values['directory'] != 'true') ...?uploadSource,
      'operation': id == 'headContent'
          ? 'getContent'
          : id == 'headWorkspaceArchive'
          ? 'downloadWorkspaceArchive'
          : id,
      'head': method == 'HEAD',
      if (body(values) case final Map<String, Object> payload)
        'body': id == 'createKey' && (values['body.expiresAt'] ?? '').isEmpty ? {...payload, 'expiresAt': null} : payload,
      'parameters': {
        for (final p in parameters)
          if (p.location != 'header' && (values[p.name] ?? '').isNotEmpty) p.name: values[p.name],
      },
      if ((values['Range'] ?? '').isNotEmpty) 'range': values['Range'],
      if ((values['If-Match'] ?? '').isNotEmpty) 'ifMatch': values['If-Match'],
      'token': token,
    });
  }

  Uri uri(Uri base, Map<String, String> values) {
    final parts = [
      'api',
      'legnasend',
      'v1',
      'integration',
      ...path.substring(1).split('/').map((part) {
        if (!part.startsWith('{')) return part;
        final name = part.substring(1, part.length - 1);
        return values[name]?.isNotEmpty == true ? values[name]! : name.toUpperCase();
      }),
    ];
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      pathSegments: parts,
      queryParameters: {
        for (final p in parameters)
          if (p.location == 'query' && (values[p.name] ?? '').isNotEmpty) p.name: values[p.name]!,
      },
    );
  }

  Map<String, String> examples(Uri base, Map<String, String> values) {
    final url = uri(base, values).toString();
    String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
    final headers = <String, String>{
      'Authorization': 'Bearer TOKEN',
      for (final p in inputParameters)
        if (p.location == 'header' && (values[p.name] ?? '').isNotEmpty) p.name: values[p.name]!,
      if (id == 'getContent' && (values['Range'] ?? '').isEmpty) 'Range': 'bytes=0-4095',
    };
    if (isTransferMutation) return _transferExamples(base, url, headers, quote, body(values, placeholders: true));
    if (isKeyMutation) {
      headers['Content-Type'] = 'application/json';
      final payload = Map<String, Object?>.from(body(values, placeholders: true)!);
      if (id == 'createKey' && payload['expiresAt'] == 0) payload['expiresAt'] = null;
      final encoded = jsonEncode(payload);
      return {
        'cURL (sh)':
            '# Requires keys.manage and *. Response can contain a one-time secret. Never auto-retry.\n'
            'umask 077\ncurl --silent --show-error --request POST ${base.scheme == 'https' ? '--cacert DEVICE_CA.pem ' : ''}${headers.entries.map((e) => '-H ${quote('${e.key}: ${e.value}')}').join(' ')} --data-binary ${quote(encoded)} --output KEY_RESPONSE.json ${quote(url)}',
        'JavaScript':
            '// Requires keys.manage and *. Keep the response in memory; do not log credentials.\n'
            'const response = await fetch(${jsonEncode(url)}, {method:"POST",headers:${jsonEncode(headers)},credentials:"omit",body:JSON.stringify($encoded)});\n'
            'const result = await response.json();\n// Deliver result.secret once to your credential vault, then clear it.\n'
            'console.log(response.status, result.receipt);\ndelete result.secret;',
        'Python':
            '# Requires keys.manage and *. Save a one-time response to an exclusive private file, not logs.\n'
            'import json, os, urllib.request\nheaders=json.loads(${jsonEncode(jsonEncode(headers))})\nheaders["Authorization"]="Bearer "+os.environ["LEGNASEND_API_TOKEN"]\n'
            'request=urllib.request.Request(${jsonEncode(url)},data=${jsonEncode(encoded)}.encode(),headers=headers,method="POST")\n'
            'with urllib.request.urlopen(request,timeout=40) as response:\n    data=response.read(262144)\n'
            'fd=os.open("KEY_RESPONSE.json",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)\nwith os.fdopen(fd,"wb") as target: target.write(data)',
      };
    }
    if (isArchiveSelection || isPreviewLease || isNativeTaskMutation || isManagement || isHostMutation || isKeyMutation || isHistoryControl) {
      return _managementExamples(base, url, headers, quote, body(values, placeholders: true));
    }
    if (isUpload) return _uploadExamples(base, values, url, headers, quote);
    return {
      'cURL (sh)':
          '${base.scheme == 'https' ? '# If this listener requires mTLS, also supply --cert CLIENT_CERT.pem --key CLIENT_KEY.pem.\n' : ''}curl ${method == 'HEAD' ? '--head' : '--request $method'} ${base.scheme == 'https' ? '--cacert DEVICE_CA.pem ' : ''}${headers.entries.map((e) => '-H ${quote('${e.key}: ${e.value}')}').join(' ')} ${quote(url)}',
      'JavaScript':
          '// Browser requests follow the configured CORS policy and client-certificate requirements.\nconst response = await fetch(${jsonEncode(url)}, {\n  method: ${jsonEncode(method)},\n  headers: ${const JsonEncoder.withIndent('  ').convert(headers)},\n  credentials: "omit",\n  signal: AbortSignal.timeout(12000),\n});\nconsole.log(response.status, await response.text());',
      'Python':
          'import json, os, ssl, urllib.request\nheaders = json.loads(${jsonEncode(jsonEncode(headers))})\nheaders["Authorization"] = "Bearer " + os.environ["LEGNASEND_API_TOKEN"]\nrequest = urllib.request.Request(${jsonEncode(url)}, headers=headers, method=${jsonEncode(method)})\ncontext = ${base.scheme == 'https' ? 'ssl.create_default_context(cafile="DEVICE_CA.pem")' : 'None'}\n${base.scheme == 'https' ? '# If mTLS is required: context.load_cert_chain("CLIENT_CERT.pem", "CLIENT_KEY.pem")\n' : ''}with urllib.request.urlopen(request, context=context, timeout=12) as response:\n    print(response.status, response.read(262144))',
    };
  }

  Map<String, String> _transferExamples(
    Uri base,
    String url,
    Map<String, String> headers,
    String Function(String) quote,
    Map<String, Object>? payload,
  ) {
    if (payload != null) headers['Content-Type'] = 'application/json';
    final encoded = payload == null ? '' : jsonEncode(payload);
    final guidance = isWorkspaceSend
        ? 'Requires transfers.send, files.read and *. Use current instanceId and generation. Filesystem selection requires exact IDs and ETags; documentSnapshot accepts issued document IDs without a fabricated version. Host captures verified private byte copies before original-protocol sending; this is not a provider-atomic tree snapshot. Keep the same requestId and payload after an unknown outcome. No automatic retries.'
        : 'Requires an explicit matching key scope and * grant. Send uses current locally selected files only. Keep REQUEST_ID and the same payload after an uncertain result; retry requires transfers.control plus transfers.send and resends ALL original task files, including already completed files and succeeded tasks; each file restarts in full. Control applies only to this key’s tasks.';
    return {
      'cURL (sh)':
          '# $guidance\n'
          'curl --include --request POST ${base.scheme == 'https' ? '--cacert DEVICE_CA.pem ' : ''}${headers.entries.map((e) => '-H ${quote('${e.key}: ${e.value}')}').join(' ')} --data-binary ${quote(encoded)} ${quote(url)}',
      'JavaScript':
          '// $guidance\n'
          'const response = await fetch(${jsonEncode(url)}, {method: "POST", headers: ${jsonEncode(headers)}, credentials: "omit", body: ${payload == null ? 'new Uint8Array(0)' : 'JSON.stringify(${jsonEncode(payload)})'}});\nconsole.log(response.status, await response.text());',
      'Python':
          '# $guidance\nimport json, os, ssl, urllib.request\n'
          'headers = json.loads(${jsonEncode(jsonEncode(headers))})\nheaders["Authorization"] = "Bearer " + os.environ["LEGNASEND_API_TOKEN"]\n'
          'body = ${payload == null ? 'b""' : 'json.dumps(json.loads(${jsonEncode(jsonEncode(payload))})).encode("utf-8")'}\n'
          'request = urllib.request.Request(${jsonEncode(url)}, data=body, headers=headers, method="POST")\n'
          'context = ${base.scheme == 'https' ? 'ssl.create_default_context(cafile="DEVICE_CA.pem")' : 'None'}\n'
          'with urllib.request.urlopen(request, context=context, timeout=40) as response:\n    print(response.status, response.read(262144))',
    };
  }

  Map<String, String> _managementExamples(
    Uri base,
    String url,
    Map<String, String> headers,
    String Function(String) quote,
    Map<String, Object>? payload,
  ) {
    if (payload != null) headers['Content-Type'] = 'application/json';
    final encoded = payload == null ? '' : jsonEncode(payload);
    return {
      'cURL (sh)':
          '# Requires ${isArchiveSelection || isPreviewLease
              ? 'files.read'
              : isHistoryControl
              ? 'requests.manage'
              : isNativeTaskMutation
              ? 'nativeTasks.control'
              : isHost
              ? (id == 'cleanupCache' ? 'cache.clean' : 'settings.write')
              : 'workspaces.manage'} and the appropriate workspace grant; host operations require *. Never auto-retry.\n'
          'curl --include --request POST ${base.scheme == 'https' ? '--cacert DEVICE_CA.pem ' : ''}${headers.entries.map((e) => '-H ${quote('${e.key}: ${e.value}')}').join(' ')} --data-binary ${quote(encoded)} ${quote(url)}',
      'JavaScript':
          '// Requires ${isArchiveSelection || isPreviewLease
              ? 'files.read'
              : isHistoryControl
              ? 'requests.manage'
              : isNativeTaskMutation
              ? 'nativeTasks.control'
              : isHost
              ? (id == 'cleanupCache' ? 'cache.clean' : 'settings.write')
              : 'workspaces.manage'}. Host operations require *. Fill local placeholders; never put secrets in URLs or logs. Browser CORS and TLS rules apply.\n'
          'const body = ${payload == null ? 'new Uint8Array(0)' : 'JSON.stringify(${jsonEncode(payload)})'};\n'
          'const response = await fetch(${jsonEncode(url)}, {method: "POST", headers: ${jsonEncode(headers)}, credentials: "omit", body: ${payload == null ? 'new Uint8Array(0)' : 'body'}});\nconsole.log(response.status, await response.text());',
      'Python':
          '# Requires ${isArchiveSelection || isPreviewLease
              ? 'files.read'
              : isHistoryControl
              ? 'requests.manage'
              : isNativeTaskMutation
              ? 'nativeTasks.control'
              : isHost
              ? (id == 'cleanupCache' ? 'cache.clean' : 'settings.write')
              : 'workspaces.manage'}. Do not automatically retry an unknown management outcome.\nimport json, os, ssl, urllib.request, urllib.error\n'
          'headers = json.loads(${jsonEncode(jsonEncode(headers))})\nheaders["Authorization"] = "Bearer " + os.environ["LEGNASEND_API_TOKEN"]\n'
          'body = ${payload == null ? 'b""' : 'json.dumps(json.loads(${jsonEncode(jsonEncode(payload))})).encode("utf-8")'}\n'
          'request = urllib.request.Request(${jsonEncode(url)}, data=${payload == null ? 'b""' : 'body'}, headers=headers, method="POST")\n'
          'context = ${base.scheme == 'https' ? 'ssl.create_default_context(cafile="DEVICE_CA.pem")' : 'None'}\n'
          'try:\n    with urllib.request.urlopen(request, context=context, timeout=40) as response:\n        print(response.status, response.read(262144))\nexcept urllib.error.HTTPError as response:\n    print(response.code, response.read(262144))',
    };
  }

  Map<String, String> _uploadExamples(
    Uri base,
    Map<String, String> values,
    String url,
    Map<String, String> headers,
    String Function(String) quote,
  ) {
    final directory = values['directory'] == 'true';
    headers['Content-Type'] = 'application/octet-stream';
    return {
      'cURL (sh)':
          '${base.scheme == 'https' ? '# If mTLS is required, supply --cert CLIENT_CERT.pem --key CLIENT_KEY.pem.\n' : ''}curl --request POST ${base.scheme == 'https' ? '--cacert DEVICE_CA.pem ' : ''}${headers.entries.map((e) => '-H ${quote('${e.key}: ${e.value}')}').join(' ')} ${directory ? "--data-binary ''" : '--upload-file FILE_PATH'} ${quote(url)}',
      'JavaScript':
          '// Browser requests follow the configured CORS and client-certificate policy.\n${directory ? 'const body = new Uint8Array(0);' : 'const body = document.querySelector(\'input[type="file"]\').files[0];\nif (!body) throw new Error("Choose a file first");'}\nconst response = await fetch(${jsonEncode(url)}, {\n  method: "POST",\n  headers: ${const JsonEncoder.withIndent('  ').convert(headers)},\n  credentials: "omit",\n  body, // Raw original bytes; the browser supplies Content-Length.\n});\nconsole.log(response.status, await response.text());',
      'Python':
          'import json, os, ssl, urllib.request\nheaders = json.loads(${jsonEncode(jsonEncode(headers))})\nheaders["Authorization"] = "Bearer " + os.environ["LEGNASEND_API_TOKEN"]\ncontext = ${base.scheme == 'https' ? 'ssl.create_default_context(cafile="DEVICE_CA.pem")' : 'None'}\n${base.scheme == 'https' ? '# If mTLS is required: context.load_cert_chain("CLIENT_CERT.pem", "CLIENT_KEY.pem")\n' : ''}${directory ? 'headers["Content-Length"] = "0"\nrequest = urllib.request.Request(${jsonEncode(url)}, data=b"", headers=headers, method="POST")\nwith urllib.request.urlopen(request, context=context, timeout=120) as response:\n    print(response.status, response.read(262144))' : 'with open("FILE_PATH", "rb") as source:\n    headers["Content-Length"] = str(os.fstat(source.fileno()).st_size)\n    request = urllib.request.Request(${jsonEncode(url)}, data=source, headers=headers, method="POST")\n    with urllib.request.urlopen(request, context=context, timeout=120) as response:\n        print(response.status, response.read(262144))'}',
    };
  }
}

class ApiCatalog {
  final List<ApiOperation> operations;
  final Map<String, dynamic> schemas;
  ApiCatalog._(this.operations, this.schemas);
  factory ApiCatalog.parse(String source) {
    final document = jsonDecode(source) as Map<String, dynamic>;
    final paths = document['paths'] as Map<String, dynamic>;
    return ApiCatalog._(
      List.unmodifiable([
        for (final path in paths.entries)
          for (final method in (path.value as Map<String, dynamic>).entries)
            if (method.key == 'get' ||
                method.key == 'head' ||
                method.key == 'post' &&
                    [
                      'prepareWorkspaceArchive',
                      'cancelWorkspaceArchive',
                      'prepareDocumentPreview',
                      'closeDocumentPreview',
                      'uploadFile',
                      'manageWorkspace',
                      'createWorkspace',
                      'scanDevices',
                      'sendSelection',
                      'sendWorkspaceFiles',
                      'controlNativeTask',
                      'retrySourceEndNotice',
                      'cancelTransfer',
                      'retryTransfer',
                      'removeTransfer',
                      'cleanupCache',
                      'updateSettings',
                      'createKey',
                      'manageKey',
                      'clearRequests',
                    ].contains((method.value as Map)['operationId']))
              ApiOperation(path.key, method.key.toUpperCase(), Map<String, dynamic>.from(method.value)),
      ]),
      Map.unmodifiable((document['components'] as Map<String, dynamic>)['schemas'] as Map<String, dynamic>),
    );
  }
}

/// Bounded display blocks, including an adversarial single unbroken JSON/text line.
List<String> apiDisplayChunks(String value) {
  final chunks = <String>[];
  for (var offset = 0; offset < value.length;) {
    var end = (offset + 2048).clamp(0, value.length);
    if (end < value.length && value.codeUnitAt(end - 1) >= 0xd800 && value.codeUnitAt(end - 1) <= 0xdbff) end--;
    chunks.add(value.substring(offset, end));
    offset = end;
  }
  return chunks;
}
