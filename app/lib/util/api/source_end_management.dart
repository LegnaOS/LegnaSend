import 'dart:convert';

import 'package:localsend_app/util/source_end_store.dart';

/// Redacted host management only. Peer cleanup capabilities never cross this API.
class SourceEndManagement {
  final Map<String, Object?> Function() read;
  final Future<Map<String, Object?>> Function(String id, String version, String requestId) retry;
  SourceEndManagement({required this.read, required this.retry});
  Future<String> execute({required String request, required Future<bool> Function() claim}) async {
    String response(int status, Map<String, Object?> body) => jsonEncode({'status': status, 'body': body});
    try {
      if (utf8.encode(request).length > 8192) throw const FormatException();
      final data = jsonDecode(request);
      if (data is! Map || data['principal'] is! String || data['workspaces'] is! List || jsonEncode(data['workspaces']) != '["*"]') {
        throw const FormatException();
      }
      final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
      if ((data['principal'] as String).isEmpty || (data['principal'] as String).length > 128) throw const FormatException();
      final op = data['operation'];
      if (op == 'nativeTasks.sourceEndList') {
        if (data.keys.any((k) => !{'operation', 'principal', 'workspaces'}.contains(k))) throw const FormatException();
        if (!await claim()) {
          return response(409, {
            'error': {'code': 'operation_expired'},
          });
        }
        return response(200, read());
      }
      if (op != 'nativeTasks.sourceEndRetry' ||
          data.keys.any((k) => !{'operation', 'principal', 'workspaces', 'noticeId', 'body'}.contains(k)) ||
          data['noticeId'] is! String) {
        throw const FormatException();
      }
      final body = data['body'];
      if (body is! Map || body.length != 2 || body['version'] is! String || body['requestId'] is! String) throw const FormatException();
      if (!uuid.hasMatch(data['noticeId']) || !uuid.hasMatch(body['version']) || !uuid.hasMatch(body['requestId'])) throw const FormatException();
      if (!await claim()) {
        return response(409, {
          'error': {'code': 'operation_expired'},
        });
      }
      return response(200, await retry(data['noticeId'], body['version'], body['requestId']));
    } on FormatException {
      return response(400, {
        'error': {'code': 'invalid_body'},
      });
    } on SourceEndStorageException catch (e) {
      return response(
        switch (e.code) {
          'notFound' => 404,
          'conflict' => 409,
          'invalid' => 400,
          _ => 503,
        },
        {
          'error': {
            'code': switch (e.code) {
              'notFound' => 'source_end_notice_not_found',
              'conflict' => 'source_end_notice_changed',
              'invalid' => 'invalid_body',
              _ => 'source_end_storage_failed',
            },
          },
        },
      );
    } catch (_) {
      return response(503, {
        'error': {'code': 'source_end_unavailable'},
      });
    }
  }
}
