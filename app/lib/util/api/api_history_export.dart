import 'dart:convert';
import 'dart:typed_data';

class ApiHistorySnapshot {
  final String instanceId;
  final int cutoff;
  final bool incomplete;
  final List<Map<String, Object?>> entries;
  const ApiHistorySnapshot(this.instanceId, this.cutoff, this.incomplete, this.entries);
  Uint8List encode({required bool csv}) {
    if (!csv) {
      return Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'format': 'legnasend-api-history',
            'version': 1,
            'instanceId': instanceId,
            'throughSequence': cutoff,
            'incomplete': incomplete,
            'entries': entries,
          }),
        ),
      );
    }
    // Fixed wire headers, never user-controlled column names or spreadsheet formulas.
    String cell(Object? value) => '"${(value?.toString() ?? '').replaceAll('"', '""')}"';
    return Uint8List.fromList(
      utf8.encode(
        '\ufeff${_fields.join(',')},incomplete\r\n${entries.map((row) => [..._fields.map((key) => cell(row[key])), incomplete.toString()].join(',')).join('\r\n')}\r\n',
      ),
    );
  }
}

const _fields = [
  'sequence',
  'timestamp',
  'requestId',
  'operation',
  'method',
  'principal',
  'status',
  'outcome',
  'error',
  'reason',
  'bytes',
  'elapsedMs',
];
final _id = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _code = RegExp(r'^[a-zA-Z][a-zA-Z0-9_.:-]{0,79}$');
int _integer(Object? value) {
  if (value is! int || value < 0 || value > 0x1fffffffffffff) throw const FormatException('Invalid history number');
  return value;
}

String _uuid(Object? value) {
  if (value is! String || !_id.hasMatch(value) || value.length != 36) throw const FormatException('Invalid history identity');
  return value;
}

String? _label(Object? value, {bool nullable = false}) {
  if (value == null && nullable) return null;
  if (value is! String || !_code.hasMatch(value)) throw const FormatException('Invalid history label');
  return value;
}

Map<String, Object?> _record(Object? value) {
  if (value is! Map) throw const FormatException('Invalid history entry');
  final status = _integer(value['status']);
  if (status < 100 || status > 599 || !['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'OTHER'].contains(value['method'])) {
    throw const FormatException('Invalid history status');
  }
  return {
    'sequence': _integer(value['sequence']),
    'timestamp': _integer(value['timestamp']),
    'requestId': _uuid(value['requestId']),
    'operation': _label(value['operation']),
    'method': value['method'],
    'principal': value['principal'] == null ? null : _uuid(value['principal']),
    'status': status,
    'outcome': _label(value['outcome']),
    'error': _label(value['error'], nullable: true),
    'reason': _label(value['reason'], nullable: true),
    'bytes': _integer(value['bytes']),
    'elapsedMs': _integer(value['elapsedMs']),
  };
}

/// Bounded capture: never chase the new audit entries produced by export itself.
/// fetch must enforce actual status/truncation and use one captured key/listener.
Future<ApiHistorySnapshot> collectApiHistory(Future<Map<String, dynamic>> Function(int after) fetch) async {
  final records = <Map<String, Object?>>[];
  String? instance;
  int? cutoff;
  var after = 0, incomplete = false;
  for (var page = 0; page < 3; page++) {
    final data = await fetch(after);
    final currentInstance = _uuid(data['instanceId']);
    if (instance != null && instance != currentInstance) throw const FormatException('History listener changed');
    instance = currentInstance;
    cutoff ??= _integer(data['latest']);
    final values = data['entries'];
    if (values is! List || values.length > 100) throw const FormatException('Invalid history page');
    final oldest = data['oldest'] == null ? null : _integer(data['oldest']);
    if (after > 0 && oldest != null && oldest > after + 1 && after < cutoff) incomplete = true;
    if (values.isEmpty) {
      if (after < cutoff && (oldest != null || cutoff > 0)) incomplete = true;
      break;
    }
    var previous = after;
    for (final value in values) {
      final record = _record(value), sequence = _integer((value as Map)['sequence']);
      if (sequence <= previous) throw const FormatException('History order changed');
      if (previous > 0 && sequence > previous + 1 && previous < cutoff) incomplete = true;
      previous = sequence;
      if (sequence > cutoff) break;
      if (records.length == 200) {
        incomplete = true;
        break;
      }
      records.add(record);
      after = sequence;
    }
    if (after >= cutoff || previous > cutoff || records.length >= 200) break;
    if (page == 2) incomplete = true;
  }
  return ApiHistorySnapshot(instance!, cutoff!, incomplete, List.unmodifiable(records));
}
