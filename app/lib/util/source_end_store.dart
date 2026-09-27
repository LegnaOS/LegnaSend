import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _id = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
const sourceEndStates = {
  'pending',
  'waitingPeer',
  'sharedSource',
  'busy',
  'authorizationRequired',
  'removed',
  'publishedPreserved',
  'unknown',
  'expired',
  'unsupported',
  'superseded',
};
const _terminal = {'removed', 'publishedPreserved', 'expired', 'unsupported', 'superseded'};

class SourceEndStorageException implements Exception {
  final String code;
  const SourceEndStorageException(this.code);
  @override
  String toString() => 'SourceEndStorageException($code)';
}

/// A separate, small, private journal. Its lock never covers source copying,
/// hashing or network I/O. Only validated redacted projections leave this store.
class SourceEndStore {
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final DateTime Function() clock;
  final Future<void> Function()? releaseLease;
  final bool Function(String peer, String key)? referenced;
  bool _closing = false, _poisoned = false;
  bool get usable => !_closing && !_poisoned;
  final _serial = AsyncSerialQueue();
  Map<String, Map<String, dynamic>> _records = {};
  Future<void>? _loading;
  SourceEndStore({required this.read, required this.write, this.clock = DateTime.now, this.releaseLease, this.referenced});
  int get now => clock().millisecondsSinceEpoch;
  static String key(String peer, String resumeKey) => sha256.convert(utf8.encode('$peer\n$resumeKey')).toString();
  Future<void> initialize() => _loading ??= _serial.run(() async {
    final raw = await read();
    if (raw == null) return;
    if (utf8.encode(raw).length > 2 * 1024 * 1024) throw const SourceEndStorageException('invalid');
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 1 || value['records'] is! List || (value['records'] as List).length > 512) {
      throw const SourceEndStorageException('invalid');
    }
    final records = <String, Map<String, dynamic>>{};
    for (final item in value['records'] as List) {
      if (item is! Map<String, dynamic>) throw const SourceEndStorageException('invalid');
      _validate(item);
      if (records.containsKey(item['key'])) throw const SourceEndStorageException('invalid');
      records[item['key'] as String] = item;
    }
    _records = records;
  });

  static void _validate(Map<String, dynamic> r) {
    if (r.keys.any(
          (k) => !{
            'key',
            'id',
            'version',
            'peer',
            'resumeKey',
            'peerLabel',
            'name',
            'route',
            'grant',
            'requested',
            'requestId',
            'state',
            'attempts',
            'updatedAtUnixMs',
            'nextAt',
            'owners',
            'endedOwners',
            'lastRetry',
            'attemptId',
            'grantAttemptId',
            'channel',
            'cleanup',
          }.contains(k),
        ) ||
        r['peer'] is! String ||
        (r['peer'] as String).isEmpty ||
        (r['peer'] as String).length > 4096 ||
        r['resumeKey'] is! String ||
        !_id.hasMatch(r['resumeKey']) ||
        r['key'] != key(r['peer'], r['resumeKey']) ||
        r['id'] is! String ||
        !_id.hasMatch(r['id']) ||
        r['version'] is! String ||
        !_id.hasMatch(r['version']) ||
        r['peerLabel'] is! String ||
        (r['peerLabel'] as String).length > 120 ||
        r['name'] is! String ||
        (r['name'] as String).length > 255 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch('${r['peerLabel']}${r['name']}') ||
        r['requested'] is! bool ||
        r['state'] is! String ||
        !sourceEndStates.contains(r['state']) ||
        r['attempts'] is! int ||
        r['attempts'] < 0 ||
        r['attempts'] > 100000 ||
        r['updatedAtUnixMs'] is! int ||
        r['nextAt'] is! int ||
        r['owners'] is! List ||
        r['endedOwners'] is! List ||
        (r['owners'] as List).length > 512 ||
        (r['endedOwners'] as List).length > 512 ||
        [...r['owners'] as List, ...r['endedOwners'] as List].any((v) => v is! String || !_id.hasMatch(v)) ||
        r['requestId'] is! String ||
        !_id.hasMatch(r['requestId']) ||
        r['attemptId'] is! String ||
        !_id.hasMatch(r['attemptId']) ||
        (r['grantAttemptId'] != null && (r['grantAttemptId'] is! String || !_id.hasMatch(r['grantAttemptId'])))) {
      throw const SourceEndStorageException('invalid');
    }
    if (r['channel'] != null && r['channel'] is! Map<String, dynamic>) throw const SourceEndStorageException('invalid');
    if (r['route'] != null && r['route'] is! Map<String, dynamic>) throw const SourceEndStorageException('invalid');
    final channel = r['channel'];
    if (channel != null &&
        (channel.length != 3 ||
            channel['host'] is! String ||
            (channel['host'] as String).isEmpty ||
            (channel['host'] as String).length > 256 ||
            channel['port'] is! int ||
            channel['port'] < 1 ||
            channel['port'] > 65535 ||
            channel['https'] is! bool)) {
      throw const SourceEndStorageException('invalid');
    }
    final route = r['route'];
    if (route != null) _validateRoute(route as Map<String, dynamic>);
    if (r.containsKey('cleanup')) _validateCleanup(r['cleanup'], r['state']);
    if (r['grant'] != null) _grant(r['grant']);
    if (r['lastRetry'] != null &&
        (r['lastRetry'] is! Map ||
            (r['lastRetry'] as Map).length != 2 ||
            r['lastRetry']['requestId'] is! String ||
            !_id.hasMatch(r['lastRetry']['requestId']) ||
            r['lastRetry']['version'] is! String ||
            !_id.hasMatch(r['lastRetry']['version']))) {
      throw const SourceEndStorageException('invalid');
    }
  }

  static void _validateRoute(Map<String, dynamic> route) {
    // Older journals contain only the required pair. The current mapper emits
    // the nullable Android pair too, including null values on desktop routes.
    if (route.keys.any((key) => !const {'interfaceName', 'localAddress', 'androidNetworkHandle', 'androidNetworkEpoch'}.contains(key))) {
      throw const SourceEndStorageException('invalid');
    }
    final name = route['interfaceName'];
    final address = route['localAddress'];
    if (name is! String ||
        name.isEmpty ||
        utf8.encode(name).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name) ||
        address is! String ||
        address.isEmpty ||
        address.length > 64 ||
        address.contains('%') ||
        InternetAddress.tryParse(address) == null) {
      throw const SourceEndStorageException('invalid');
    }
    final handle = route['androidNetworkHandle'];
    final epoch = route['androidNetworkEpoch'];
    if ((handle == null) != (epoch == null)) throw const SourceEndStorageException('invalid');
    if (handle == null) return;
    // Android returns an unsigned decimal network handle. Never truncate it to
    // a signed Dart int or accept a leading zero/sign as a different identity.
    if (handle is! String ||
        !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(handle) ||
        BigInt.parse(handle) > ((BigInt.one << 64) - BigInt.one) ||
        epoch is! String ||
        epoch.length != 73) {
      throw const SourceEndStorageException('invalid');
    }
    final identity = epoch.split(':');
    if (identity.length != 2 || identity.any((part) => !_id.hasMatch(part))) {
      throw const SourceEndStorageException('invalid');
    }
    // This is persisted syntax, not a claim that the network is still alive.
    // Dispatch retains the existing live snapshot and Rust socket checks.
  }

  // A receipt contains no authority, path or source identity. Missing receipt
  // data in older journals stays absent: never reconstruct counters from size.
  static void _validateCleanup(dynamic data, String state) {
    if (!const {'removed', 'publishedPreserved'}.contains(state) ||
        data is! Map ||
        data.length != 3 ||
        data['receiptId'] is! String ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(data['receiptId']) ||
        data['removedFiles'] is! int ||
        data['removedFiles'] < 0 ||
        data['removedFiles'] > 2 ||
        data['unlinkedBytes'] is! int ||
        data['unlinkedBytes'] < 0 ||
        (data['removedFiles'] == 0 && data['unlinkedBytes'] != 0)) {
      throw const SourceEndStorageException('invalidReceipt');
    }
  }

  static SourceEndGrant _grant(dynamic data) {
    if (data is! Map ||
        data.length != 5 ||
        data['version'] != 1 ||
        data['grantId'] is! String ||
        !_id.hasMatch(data['grantId']) ||
        data['round'] is! String ||
        !_id.hasMatch(data['round']) ||
        data['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(data['token']) ||
        data['expiresAtUnixMs'] is! int ||
        data['expiresAtUnixMs'] <= 0 ||
        data['expiresAtUnixMs'] > 9007199254740991) {
      throw const SourceEndStorageException('invalid');
    }
    return SourceEndGrant(version: 1, grantId: data['grantId'], round: data['round'], token: data['token'], expiresAtUnixMs: data['expiresAtUnixMs']);
  }

  static Map<String, dynamic> _grantMap(SourceEndGrant g) => {
    'version': g.version,
    'grantId': g.grantId,
    'round': g.round,
    'token': g.token,
    'expiresAtUnixMs': g.expiresAtUnixMs,
  };
  static String _label(String value, int limit) {
    final out = StringBuffer();
    var units = 0;
    for (final rune in value.runes) {
      final width = rune > 0xffff ? 2 : 1;
      if (units + width > limit) break;
      units += width;
      out.writeCharCode(rune < 32 || rune >= 127 && rune <= 159 ? 32 : rune);
    }
    return out.toString();
  }

  Future<T> _change<T>(T Function(Map<String, Map<String, dynamic>>) change) async {
    await initialize();
    if (_closing) throw const SourceEndStorageException('closed');
    return _serial.run(() async {
      if (_poisoned) throw const SourceEndStorageException('commitUnknown');
      final next = (jsonDecode(jsonEncode(_records)) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as Map<String, dynamic>));
      final result = change(next);
      for (final r in next.values) {
        _validate(r);
      }
      final encoded = jsonEncode({'version': 1, 'records': next.values.toList()});
      if (encoded == jsonEncode({'version': 1, 'records': _records.values.toList()})) return result;
      if (utf8.encode(encoded).length > 2 * 1024 * 1024) throw const SourceEndStorageException('full');
      try {
        await write(encoded);
      } catch (_) {
        _poisoned = true;
        throw const SourceEndStorageException('commitUnknown');
      }
      _records = next;
      return result;
    });
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _serial.run(() async {
      await releaseLease?.call();
    });
  }

  Future<bool> track({
    required String jobId,
    required String peer,
    required String resumeKey,
    required String peerLabel,
    required String name,
    required String attemptId,
    Map<String, dynamic>? route,
    Map<String, dynamic>? channel,
  }) =>
      _change((rows) {
        if (!_id.hasMatch(jobId) || !_id.hasMatch(resumeKey) || !_id.hasMatch(attemptId)) throw const SourceEndStorageException('invalid');
        final k = key(peer, resumeKey);
        var r = rows[k];
        if (r != null && r['requested'] == true) return false; // ended source keys never revive
        if (r == null) {
          if (rows.length >= 512) {
            final terminal =
                rows.entries
                    .where(
                      (e) =>
                          (e.value['requested'] == false && const {'publishedPreserved', 'unsupported'}.contains(e.value['state'])) ||
                          (_terminal.contains(e.value['state']) &&
                              (e.value['owners'] as List).isEmpty &&
                              referenced?.call(e.value['peer'], e.value['resumeKey']) != true),
                    )
                    .toList()
                  ..sort((a, b) => (a.value['updatedAtUnixMs'] as int).compareTo(b.value['updatedAtUnixMs']));
            if (terminal.isEmpty) return false;
            rows.remove(terminal.first.key);
          }
          r = {
            'key': k,
            'id': _uuid.v4(),
            'version': _uuid.v4(),
            'peer': peer,
            'resumeKey': resumeKey,
            'peerLabel': _label(peerLabel, 120),
            'name': _label(name.split(RegExp(r'[/\\]')).last, 255),
            'route': route,
            'channel': channel,
            'grant': null,
            'requested': false,
            'requestId': _uuid.v4(),
            'state': 'pending',
            'attempts': 0,
            'updatedAtUnixMs': now,
            'nextAt': 0,
            'owners': <String>[],
            'endedOwners': <String>[],
            'lastRetry': null,
            'attemptId': attemptId,
            'grantAttemptId': null,
          };
          rows[k] = r;
        }
        r['attemptId'] = attemptId;
        if ((!(r['owners'] as List).contains(jobId) && !(r['endedOwners'] as List).contains(jobId))) (r['owners'] as List).add(jobId);
        // Leave room for later grants, retries and end-owner intent metadata.
        if (utf8.encode(jsonEncode(rows)).length > 1536 * 1024) throw const SourceEndStorageException('full');
        return true;
      }).catchError((Object error) {
        if (error is SourceEndStorageException && error.code == 'full') return false;
        throw error;
      });
  Future<void> recordGrant({
    required String peer,
    required String resumeKey,
    required String jobId,
    required String attemptId,
    required SourceEndGrant grant,
  }) => _change((rows) {
    _grant(_grantMap(grant));
    final r = rows[key(peer, resumeKey)];
    if (r == null || r['attemptId'] != attemptId || (!(r['owners'] as List).contains(jobId) && !(r['endedOwners'] as List).contains(jobId))) {
      throw const SourceEndStorageException('stale');
    }
    final existing = r['grant'];
    if (existing != null && r['grantAttemptId'] == attemptId && existing['round'] != grant.round) {
      throw const SourceEndStorageException('roundChanged');
    }
    if (existing != null && existing['round'] != grant.round) {
      r['requestId'] = _uuid.v4();
      r['lastRetry'] = null;
    }
    r.remove('cleanup');
    r['grant'] = _grantMap(grant);
    r['grantAttemptId'] = attemptId;
    r['version'] = _uuid.v4();
    r['updatedAtUnixMs'] = now;
    r['state'] = 'pending';
    r['nextAt'] = 0;
  });
  Future<void> completed(String peer, String resumeKey) => _change((rows) {
    final r = rows[key(peer, resumeKey)];
    if (r == null || r['cleanup'] != null) return; // Preserve an already confirmed receiver receipt.
    // Local completion is not a receiver cleanup receipt.
    r['state'] = 'publishedPreserved';
    r['version'] = _uuid.v4();
    r['updatedAtUnixMs'] = now;
  });
  Future<void> unsupported(String peer, String resumeKey, String attemptId) => _change((rows) {
    final r = rows[key(peer, resumeKey)];
    if (r == null || r['attemptId'] != attemptId || r['grant'] != null) return;
    r.remove('cleanup');
    r['state'] = 'unsupported';
    r['version'] = _uuid.v4();
    r['updatedAtUnixMs'] = now;
  });
  Future<void> requestEnd(String jobId, {String? onlyKey}) => _change((rows) {
    for (final r in rows.values.where((r) => (r['owners'] as List).contains(jobId) && (onlyKey == null || r['key'] == onlyKey))) {
      if (!(r['endedOwners'] as List).contains(jobId)) (r['endedOwners'] as List).add(jobId);
      r['requested'] = true;
      if (!_terminal.contains(r['state'])) r['state'] = r['grant'] == null ? 'unknown' : 'pending';
      r['version'] = _uuid.v4();
      r['updatedAtUnixMs'] = now;
      r['nextAt'] = 0;
    }
  });
  Future<void> detachOwner(String jobId) => _change((rows) {
    for (final r in rows.values) {
      (r['owners'] as List).remove(jobId);
    }
  });
  bool ended(String peer, String resumeKey) {
    if (_poisoned) throw const SourceEndStorageException('commitUnknown');
    return _records[key(peer, resumeKey)]?['requested'] == true;
  }

  Set<String> endedOwners(String peer, String resumeKey) => Set<String>.from(_records[key(peer, resumeKey)]?['endedOwners'] ?? const []);
  List<Map<String, Object?>> notices() => [
    for (final r in _records.values)
      if (r['requested'] == true) _view(r),
  ];
  Map<String, Object?> _view(Map<String, dynamic> r) => {
    for (final k in ['id', 'version', 'peerLabel', 'name', 'state', 'attempts', 'updatedAtUnixMs']) k: r[k],
    if (r['cleanup'] != null) 'cleanup': Map<String, Object?>.unmodifiable(r['cleanup'] as Map<String, dynamic>),
  };
  bool get hasScheduled =>
      !_poisoned &&
      _records.values.any(
        (r) => r['requested'] == true && r['grant'] != null && !_terminal.contains(r['state']) && r['state'] != 'authorizationRequired',
      );
  List<SourceEndDispatch> pending() => _poisoned
      ? []
      : [
          for (final r in _records.values)
            if (r['requested'] == true &&
                r['grant'] != null &&
                !_terminal.contains(r['state']) &&
                r['state'] != 'authorizationRequired' &&
                r['nextAt'] <= now)
              SourceEndDispatch(r['id'], r['version'], r['peer'], r['resumeKey'], r['requestId'], r['route'], r['channel'], _grant(r['grant'])),
        ];
  Future<void> outcome(SourceEndDispatch d, String state, {bool attempted = false, SourceEndResult? confirmation}) => _change((rows) {
    final r = rows[key(d.peer, d.resumeKey)];
    if (r == null || r['version'] != d.version) return;
    Map<String, Object?>? cleanup;
    if (confirmation != null && const {'removed', 'publishedPreserved'}.contains(state)) {
      if ((state == 'removed' && confirmation.outcome != SourceEndOutcome.cleared) ||
          (state == 'publishedPreserved' && confirmation.outcome != SourceEndOutcome.publishedPreserved)) {
        throw const SourceEndStorageException('invalidReceipt');
      }
      cleanup = {
        'receiptId': confirmation.receiptId,
        'removedFiles': confirmation.removedFiles,
        'unlinkedBytes': confirmation.unlinkedBytes,
      };
      _validateCleanup(cleanup, state);
    }
    r.remove('cleanup');
    if (cleanup != null) r['cleanup'] = cleanup;
    r['state'] = state;
    r['version'] = _uuid.v4();
    r['updatedAtUnixMs'] = now;
    if (attempted) r['attempts'] = (r['attempts'] as int) + 1;
    final attempts = (r['attempts'] as int).clamp(0, 8);
    r['nextAt'] = now + (1000 * (1 << attempts)).clamp(5000, 300000);
  });
  Future<Map<String, Object?>> retry(String id, String version, String requestId) => _change((rows) {
    if (!_id.hasMatch(id) || !_id.hasMatch(version) || !_id.hasMatch(requestId)) throw const SourceEndStorageException('invalid');
    final r = rows.values.where((r) => r['id'] == id && r['requested'] == true).firstOrNull;
    if (r == null) throw const SourceEndStorageException('notFound');
    if (r['lastRetry']?['requestId'] == requestId) {
      if (r['lastRetry']['version'] != version) throw const SourceEndStorageException('conflict');
      return _view(r);
    }
    if (r['version'] != version || _terminal.contains(r['state'])) throw const SourceEndStorageException('conflict');
    r.remove('cleanup');
    r['lastRetry'] = {'version': version, 'requestId': requestId};
    r['state'] = r['grant'] == null ? 'unknown' : 'pending';
    r['nextAt'] = 0;
    r['version'] = _uuid.v4();
    r['updatedAtUnixMs'] = now;
    return _view(r);
  });
}

/// Transport-only snapshot, never used as provider state or an API response.
class SourceEndDispatch {
  final String id, version, peer, resumeKey, requestId;
  final Map<String, dynamic>? route, channel;
  final SourceEndGrant grant;
  SourceEndDispatch(this.id, this.version, this.peer, this.resumeKey, this.requestId, this.route, this.channel, this.grant);
  @override
  String toString() => 'SourceEndDispatch(redacted)';
}
