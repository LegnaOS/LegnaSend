import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

typedef DirectoryWriteReply =
    Future<bool> Function({required String requestId, String? payload, int? cacheDescriptor, int? stagingDescriptor, String? error});
typedef DirectoryWriteInvoke = Future<Object?> Function(String request);

/// One listener's private workspace transactions. No native receive-session IDs
/// are invented. Late platform replies always return to the captured Rust owner.
class DirectoryWriteProvider {
  static const _channel = MethodChannel('org.localsend.localsend_app/localsend');
  static final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
  static int _actualWork = 0;
  final DirectoryWriteReply reply;
  final bool Function() isCurrent;
  final bool android;
  final DirectoryWriteInvoke invoke;
  final Duration beginTimeout;
  final _pending = <String, _WriteRequest>{};
  final _transactions = <String, Map<String, dynamic>>{};
  final _starting = <String>{};
  bool _closed = false;

  DirectoryWriteProvider({
    required this.reply,
    required this.isCurrent,
    bool? android,
    DirectoryWriteInvoke? invoke,
    this.beginTimeout = const Duration(seconds: 30),
  }) : android = android ?? Platform.isAndroid,
       invoke = invoke ?? _invoke;
  static Future<Object?> _invoke(String request) => _channel.invokeMethod<Object?>('workspaceDocumentWrite', {'request': request});
  int get pendingCount => _pending.length;
  int get transactionCount => _transactions.length;

  Future<bool?> _respond(String id, {String? payload, int? cache, int? staging, String? error}) async {
    try {
      // Calling this function transfers each detached descriptor exactly once.
      // Rust adopts both before lookup and closes malformed/stale responses.
      return await reply(requestId: id, payload: payload, cacheDescriptor: cache, stagingDescriptor: staging, error: error);
    } catch (_) {
      // Transport failure does not prove Rust rejected the descriptors: it may
      // already own them. Retain journal ownership, never guess FD closure.
      return null;
    }
  }

  Future<void> _control(Map<String, dynamic> request) async {
    try {
      await invoke(jsonEncode(request))
          .then((value) async {
            // Controls never return descriptors. Defensively consume a malformed
            // late reply through the original RAII bridge as well.
            final cache = value is Map && value['cacheFd'] is int ? value['cacheFd'] as int : null;
            final staging = value is Map && value['stagingFd'] is int ? value['stagingFd'] as int : null;
            if (cache != null || staging != null) await _respond(request['requestId'] as String, cache: cache, staging: staging, error: 'invalid');
          })
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Native journal retains unresolved ownership. */
    }
  }

  Future<void> cancelRequest(String id) async {
    final pending = _pending[id];
    if (pending == null || pending.cancelled || pending.operation == 'publish') return;
    pending.cancelled = true;
    pending.timer?.cancel();
    await Future.wait([
      _control({'version': 1, 'op': 'cancelRequest', 'requestId': id}),
      _respond(id, error: 'cancelled'),
    ]);
    // Do not release the global work budget while the native invocation is stuck.
  }

  Map<String, dynamic> _decode(String id, String request) {
    if (utf8.encode(request).length > 65536) throw const FormatException();
    final value = jsonDecode(request) as Map<String, dynamic>;
    if (value['version'] != 1 ||
        value['requestId'] != id ||
        !_uuid.hasMatch(id) ||
        !const {'begin', 'publish', 'release', 'cancel'}.contains(value['op']) ||
        value['owner'] is! String ||
        !_uuid.hasMatch(value['owner']) ||
        value['attemptId'] is! String ||
        !_uuid.hasMatch(value['attemptId']) ||
        value['workspaceId'] is! String ||
        !_uuid.hasMatch(value['workspaceId']) ||
        value['generation'] is! int ||
        (value['generation'] as int) < 1 ||
        value['tree'] is! String ||
        !(value['tree'] as String).startsWith('content://')) {
      throw const FormatException();
    }
    if (value['op'] != 'begin' &&
        !(value['op'] == 'release' && value['transactionId'] == null && value['lease'] == null) &&
        (value['transactionId'] is! String ||
            !_uuid.hasMatch(value['transactionId']) ||
            value['lease'] is! String ||
            (value['lease'] as String).isEmpty ||
            utf8.encode(value['lease']).length > 256)) {
      throw const FormatException();
    }
    return value;
  }

  bool _matches(Map<String, dynamic> a, Map<String, dynamic> b) =>
      const ['owner', 'workspaceId', 'generation', 'tree', 'attemptId', 'transactionId', 'lease'].every((key) => a[key] == b[key]);

  Future<void> handle(String id, String request) async {
    if (!android) {
      await _respond(id, error: 'unsupported');
      return;
    }
    final Map<String, dynamic> value;
    try {
      value = _decode(id, request);
    } catch (_) {
      await _respond(id, error: 'invalid');
      return;
    }
    final operation = value['op'] as String, attempt = value['attemptId'] as String;
    final control = operation == 'release' || operation == 'cancel';
    final owned = _transactions[attempt];
    if (operation == 'begin') {
      if (_closed || !isCurrent()) {
        await _respond(id, error: 'cancelled');
        return;
      }
      if (_transactions.length + _starting.length >= 8 || owned != null || _starting.contains(attempt)) {
        await _respond(id, error: 'busy');
        return;
      }
    } else if (owned == null ||
        !(operation == 'release' && value['transactionId'] == null && value['lease'] == null
            ? const ['owner', 'workspaceId', 'generation', 'tree', 'attemptId'].every((key) => value[key] == owned[key])
            : _matches(value, owned))) {
      await _respond(id, error: 'invalid');
      return;
    }
    if (_pending.containsKey(id) || _pending.length >= 24 || (!control && _actualWork >= 8)) {
      await _respond(id, error: 'busy');
      return;
    }
    final pending = _WriteRequest(operation);
    _pending[id] = pending;
    if (operation == 'begin') _starting.add(attempt);
    if (!control) _actualWork++;
    if (operation == 'begin') pending.timer = Timer(beginTimeout, () => unawaited(cancelRequest(id)));
    try {
      final result = await invoke(
        operation == 'release' && value['transactionId'] == null
            ? jsonEncode({...value, 'transactionId': owned!['transactionId'], 'lease': owned['lease']})
            : request,
      );
      final rawCache = result is Map ? result['cacheFd'] : null, rawStaging = result is Map ? result['stagingFd'] : null;
      final cache = rawCache is int && rawCache >= 0 ? rawCache : null, staging = rawStaging is int && rawStaging >= 0 ? rawStaging : null;
      final payload = result is Map ? result['payload'] : null;
      Map<String, dynamic>? data;
      if (payload is String && utf8.encode(payload).length <= 16384) {
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {}
      }
      Map<String, dynamic>? transaction;
      if (operation == 'begin' &&
          data?['transactionId'] is String &&
          _uuid.hasMatch(data!['transactionId']) &&
          data['lease'] is String &&
          (data['lease'] as String).isNotEmpty &&
          utf8.encode(data['lease']).length <= 256) {
        transaction = {...value, 'transactionId': data['transactionId'], 'lease': data['lease']};
      }
      final validDescriptors = operation == 'begin'
          ? value['directory'] == true
                ? cache == null && staging == null
                : cache != null && staging != null && cache != staging
          : cache == null && staging == null;
      final valid =
          data?['version'] == 1 &&
          validDescriptors &&
          (rawCache == null || cache != null) &&
          (rawStaging == null || staging != null) &&
          (operation != 'begin' || transaction != null) &&
          (operation != 'publish' || data?['published'] == true);
      final staleBegin = operation == 'begin' && (pending.cancelled || _closed || !isCurrent());
      if (!valid || staleBegin) {
        final consumed = await _respond(
          id,
          cache: cache,
          staging: staging,
          error: operation == 'publish'
              ? 'publication_unconfirmed'
              : staleBegin
              ? 'cancelled'
              : 'invalid',
        );
        // Rust has now consumed/closed rejected begin FDs. Only then release.
        if (operation == 'begin') {
          if (consumed == null) {
            if (transaction != null) _transactions[attempt] = transaction;
            await _control({
              ...value,
              if (transaction != null) ...transaction,
              'op': transaction == null ? 'cancelRequest' : 'cancel',
              'requestId': transaction == null ? id : const Uuid().v4(),
            });
            return;
          }
          await _control({
            ...value,
            if (transaction != null) ...transaction,
            if (transaction == null) 'transactionId': null,
            if (transaction == null) 'lease': null,
            'op': 'release',
            'requestId': const Uuid().v4(),
          });
        }
        return;
      }
      if (operation == 'begin') _transactions[attempt] = transaction!;
      final accepted = await _respond(id, payload: payload as String, cache: cache, staging: staging);
      if (operation == 'begin' && accepted == false) {
        _transactions.remove(attempt);
        await _control({...transaction!, 'op': 'release', 'requestId': const Uuid().v4()});
      } else if (operation == 'begin' && accepted == null) {
        await _control({...transaction!, 'op': 'cancel', 'requestId': const Uuid().v4()});
      } else if (operation == 'release') {
        _transactions.remove(attempt);
      }
      // Publication after stop is a real result, not inferred cancellation.
      // Its transaction remains owned until core confirms both FDs closed.
    } on PlatformException catch (error) {
      if (!pending.cancelled || operation == 'publish') {
        const codes = {
          'invalid',
          'permission',
          'not_found',
          'unsupported',
          'busy',
          'expired',
          'cancelled',
          'provider_error',
          'conflict',
          'publication_unconfirmed',
        };
        final code = codes.contains(error.code) ? error.code : 'provider_error';
        await _respond(id, error: operation == 'publish' ? 'publication_unconfirmed' : code);
      }
    } catch (_) {
      if (!pending.cancelled || operation == 'publish') {
        await _respond(id, error: operation == 'publish' ? 'publication_unconfirmed' : 'provider_error');
      }
    } finally {
      pending.timer?.cancel();
      _pending.remove(id);
      if (operation == 'begin') _starting.remove(attempt);
      if (!control) _actualWork--;
    }
  }

  /// Does not await a blocked publication, destroy an active descriptor lease,
  /// or close the old result sink. Core drains only its bounded admitted owners.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([
      for (final id in _pending.keys.toList())
        if (_pending[id]!.operation == 'begin') cancelRequest(id),
    ]);
    for (final transaction in _transactions.values.toList()) {
      unawaited(_control({...transaction, 'op': 'cancel', 'requestId': const Uuid().v4()}));
    }
  }
}

class _WriteRequest {
  final String operation;
  Timer? timer;
  bool cancelled = false;
  _WriteRequest(this.operation);
}
