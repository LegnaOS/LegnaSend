import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/util/async_serial_queue.dart';

/// Another local/API policy change is still committing its runtime state.
class HostSettingsBusy implements Exception {
  const HostSettingsBusy();
}

/// Global host control, independent of workspace grants and send task ownership.
/// Callbacks return explicitly redacted data, never generic provider snapshots.
class HostManagement {
  final Map<String, Object> Function() readSettings;
  final Future<void> Function(String field, Object value) writeSetting;
  final Future<Map<String, Object>> Function(bool cleanup) cache;
  final List<String> Function()? pendingRestart;
  final Map<String, Object?> Function()? receiveCacheRetention;
  final _serial = AsyncSerialQueue();
  HostManagement({required this.readSettings, required this.writeSetting, required this.cache, this.pendingRestart, this.receiveCacheRetention});
  Map<String, Object> _snapshot() {
    final settings = readSettings();
    final pending = pendingRestart?.call() ?? <String>[];
    final retention =
        receiveCacheRetention?.call() ??
        {
          'effectiveDays': null,
          'automaticCleanupPaused': true,
          'busy': false,
          'error': null,
        };
    return {
      'version': sha256.convert(utf8.encode(jsonEncode([settings, pending, retention]))).toString(),
      'settings': settings,
      'pendingRestart': pending,
      'receiveCacheRetention': retention,
    };
  }

  Future<String> execute({required String request, required Future<bool> Function() claim}) => _serial.run(() async {
    String response(int status, Map<String, Object> body) => jsonEncode({'status': status, 'body': body});
    String fail(int status, String code) => response(status, {
      'error': {'code': code},
    });
    try {
      final value = jsonDecode(request) as Map<String, dynamic>;
      if (value['principal'] is! String || value['workspaces'] is! List || !(value['workspaces'] as List).contains('*')) {
        return fail(403, 'global_host_key_required');
      }
      final op = value['operation'];
      if (!['host.cache.inspect', 'host.cache.cleanup', 'host.settings.read', 'host.settings.update'].contains(op)) {
        return fail(400, 'invalid_operation');
      }
      if (op == 'host.settings.update') {
        final change = value['change'];
        if (change is! Map || change.length != 3 || change['version'] is! String || change['field'] is! String || change['value'] == null) {
          return fail(400, 'invalid_body');
        }
        final fields = readSettings();
        final field = change['field'] as String;
        final next = change['value'];
        if (!fields.containsKey(field)) return fail(400, 'invalid_setting');
        if (field == 'receiveCacheRetentionDays') {
          if (next is! int || next < -1 || next > 3650) return fail(400, 'invalid_setting');
        } else if (fields[field] is bool ? next is! bool : next is! String) {
          return fail(400, 'invalid_setting');
        }
        if (next is String && (next.length > 120 || next.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(next))) {
          return fail(400, 'invalid_setting');
        }
        if (field == 'theme' && !['system', 'light', 'dark'].contains(next)) return fail(400, 'invalid_setting');
        if (change['version'] != _snapshot()['version']) return fail(409, 'settings_changed');
        if (!await claim()) return fail(409, 'operation_expired');
        if (change['version'] != _snapshot()['version']) return fail(409, 'settings_changed');
        await writeSetting(field, next as Object);
        return response(200, _snapshot());
      }
      if (!await claim()) return fail(409, 'operation_expired');
      return response(200, op == 'host.settings.read' ? _snapshot() : await cache(op == 'host.cache.cleanup'));
    } on HostSettingsBusy {
      return fail(409, 'settings_busy');
    } on FormatException {
      return fail(400, 'invalid_setting');
    } catch (_) {
      return fail(503, 'host_operation_failed');
    }
  });
}
