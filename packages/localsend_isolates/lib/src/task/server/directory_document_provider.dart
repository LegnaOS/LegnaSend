import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

typedef DirectoryDocumentReply = Future<bool> Function({required String requestId, String? payload, int? fileDescriptor, String? error});
typedef DocumentInvoke = Future<Object?> Function(String request);

/// One listener's bounded platform requests. Every callback retains its original
/// Rust responder; a late detached FD is never sent to a replacement listener.
class DirectoryDocumentProvider {
  final DirectoryDocumentReply reply;
  final bool Function() isCurrent;
  final bool android;
  final DocumentInvoke invoke;
  final Duration timeout;
  final _pending = <String, _Request>{};
  final _scopes = <String, Map<String, Object?>>{};
  bool _closed = false;
  DirectoryDocumentProvider({
    required this.reply,
    required this.isCurrent,
    bool? android,
    DocumentInvoke? invoke,
    this.timeout = const Duration(seconds: 10),
  }) : android = android ?? Platform.isAndroid,
       invoke = invoke ?? _invoke;
  static const _channel = MethodChannel('org.localsend.localsend_app/localsend');
  static Future<Object?> _invoke(String request) => _channel.invokeMethod<Object?>('workspaceDocuments', {'request': request});
  int get pendingCount => _pending.length;

  Future<void> _respond(String id, {String? payload, int? fd, String? error}) async {
    try {
      // Ownership is transferred exactly once when reply is invoked. Never
      // attempt to re-adopt/close the integer after a bridge error.
      await reply(requestId: id, payload: payload, fileDescriptor: fd, error: error);
    } catch (_) {
      /* Rust rejects stale responses and owns descriptor cleanup. */
    }
  }

  Future<void> _control(Map<String, Object?> request) async {
    try {
      await invoke(jsonEncode(request)).timeout(timeout);
    } catch (_) {}
  }

  Future<void> cancel(String id, {String error = 'cancelled'}) async {
    final pending = _pending[id];
    if (pending == null || pending.cancelled) return;
    pending.cancelled = true;
    pending.timer?.cancel();
    // Keep the pending slot until the original platform invocation returns. A
    // provider ignoring cancellation does not create unbounded detached awaits.
    await Future.wait([
      _control({'version': 1, 'op': 'cancel', 'requestId': id}),
      _respond(id, error: error),
    ]);
  }

  Future<void> handle(String id, String request) async {
    if (_closed || !isCurrent()) {
      await _respond(id, error: 'cancelled');
      return;
    }
    if (!android) {
      await _respond(id, error: 'unsupported');
      return;
    }
    if (_pending.length >= 16 || _pending.containsKey(id)) {
      await _respond(id, error: 'busy');
      return;
    }
    Map<String, dynamic> decoded;
    String? scope;
    try {
      if (request.length > 65536) throw const FormatException();
      decoded = jsonDecode(request) as Map<String, dynamic>;
      if (decoded['version'] != 1 ||
          decoded['requestId'] != id ||
          !const {'probe', 'list', 'open', 'close', 'state'}.contains(decoded['op']) ||
          decoded['owner'] is! String ||
          !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$').hasMatch(decoded['owner'] as String) ||
          decoded['workspaceId'] is! String ||
          decoded['generation'] is! int ||
          decoded['tree'] is! String) {
        throw const FormatException();
      }
      if (decoded['op'] != 'probe') {
        scope = jsonEncode([decoded['owner'], decoded['workspaceId'], decoded['generation'], decoded['tree']]);
        if (decoded['op'] != 'close') {
          if (!_scopes.containsKey(scope) && _scopes.length >= 256) {
            await _respond(id, error: 'busy');
            return;
          }
          _scopes[scope] = {
            'owner': decoded['owner'],
            'workspaceId': decoded['workspaceId'],
            'generation': decoded['generation'],
            'tree': decoded['tree'],
          };
        }
      }
    } catch (_) {
      await _respond(id, error: 'invalid');
      return;
    }
    final pending = _Request();
    _pending[id] = pending;
    pending.timer = Timer(timeout, () => unawaited(cancel(id, error: 'expired')));
    try {
      final value = await invoke(request);
      // Capture an owned descriptor even when the accompanying metadata is bad.
      final rawFd = value is Map ? value['fd'] : null;
      final fd = rawFd is int && rawFd >= 0 ? rawFd : null;
      if (pending.cancelled || _closed || !isCurrent()) {
        if (fd != null) {
          await _respond(id, fd: fd, error: 'cancelled');
        } else if (!pending.cancelled) {
          await _respond(id, error: 'cancelled');
        }
        return;
      }
      final payload = value is Map ? value['payload'] : null;
      if (payload is! String || payload.length > 2 * 1024 * 1024 || (rawFd != null && fd == null)) {
        await _respond(id, fd: fd, error: 'invalid');
      } else {
        await _respond(id, payload: payload, fd: fd);
        if (decoded['op'] == 'close') _scopes.remove(scope);
      }
    } on PlatformException catch (error) {
      if (!pending.cancelled) {
        const codes = {'invalid', 'permission', 'not_found', 'unsupported', 'busy', 'expired', 'cancelled', 'provider_error', 'loading'};
        await _respond(id, error: codes.contains(error.code) ? error.code : 'provider_error');
      }
    } catch (_) {
      if (!pending.cancelled) await _respond(id, error: 'provider_error');
    } finally {
      pending.timer?.cancel();
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final scopes = _scopes.values.toList(growable: false);
    _scopes.clear();
    await Future.wait([for (final id in _pending.keys.toList()) cancel(id)]);
    // Do not await every provider at once or retain an unbounded owner list.
    for (final scope in scopes) {
      await _control({'version': 1, 'requestId': const Uuid().v4(), 'op': 'close', ...scope});
    }
  }
}

class _Request {
  bool cancelled = false;
  Timer? timer;
}
