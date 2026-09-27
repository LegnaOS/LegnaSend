import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_history_export.dart';

const id = '11111111-1111-4111-8111-111111111111';
Map<String, dynamic> entry(int n) => {
  'sequence': n,
  'timestamp': 123,
  'requestId': id,
  'operation': 'getStatus',
  'method': 'GET',
  'principal': null,
  'status': 200,
  'outcome': 'complete',
  'error': null,
  'reason': null,
  'bytes': 4,
  'elapsedMs': 1,
};
Map<String, dynamic> page(List<int> nums, {int latest = 200, int? oldest = 1, String instance = id}) => {
  'instanceId': instance,
  'entries': nums.map(entry).toList(),
  'latest': latest,
  'oldest': oldest,
};
void main() {
  test('bounded capture excludes new export requests and strips arbitrary private fields', () async {
    var calls = 0;
    final s = await collectApiHistory((after) async {
      calls++;
      final p = page(List.generate(100, (i) => after + i + 1), latest: calls == 1 ? 150 : 155);
      (p['entries'] as List).first['token'] = 'SECRET';
      (p['entries'] as List).first['path'] = '/private';
      return p;
    });
    expect(calls, 2);
    expect(s.entries.length, 150);
    expect(s.cutoff, 150);
    expect(s.incomplete, false);
    final json = utf8.decode(s.encode(csv: false));
    expect(json, isNot(contains('SECRET')));
    expect(json, isNot(contains('/private')));
    expect(utf8.decode(s.encode(csv: true)), startsWith('sequence,timestamp'));
  });
  test('retention rollover is explicit and listener replacement aborts', () async {
    var calls = 0;
    final s = await collectApiHistory((after) async {
      calls++;
      return calls == 1 ? page([1, 2], latest: 5) : page([4, 5], latest: 6, oldest: 4);
    });
    expect(s.incomplete, true);
    calls = 0;
    await expectLater(
      collectApiHistory((after) async {
        calls++;
        return calls == 1 ? page([1], latest: 2) : page([2], latest: 2, instance: '22222222-2222-4222-8222-222222222222');
      }),
      throwsFormatException,
    );
  });
  test('reject formulas, duplicate sequence, secret-shaped labels and oversized pages', () async {
    for (final field in ['operation', 'outcome', 'error', 'reason']) {
      final p = page([1], latest: 1);
      p['entries'][0][field] = '=HYPERLINK("secret")';
      await expectLater(collectApiHistory((_) async => p), throwsFormatException);
    }
    await expectLater(collectApiHistory((_) async => page([1, 1], latest: 1)), throwsFormatException);
    await expectLater(collectApiHistory((_) async => page(List.generate(101, (i) => i + 1))), throwsFormatException);
  });
  test('empty history and short pages remain bounded', () async {
    final empty = await collectApiHistory((_) async => page([], latest: 0, oldest: null));
    expect(empty.entries, isEmpty);
    expect(empty.incomplete, false);
    var calls = 0;
    final short = await collectApiHistory((after) async {
      calls++;
      return page([after + 1]);
    });
    expect(calls, 3);
    expect(short.incomplete, true);
  });
}
