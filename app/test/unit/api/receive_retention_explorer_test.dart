import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';

void main() {
  final operation = ApiOperation('/settings/update', 'POST', {'operationId': 'updateSettings'});
  Map<String, String> values(String value) => {'body.version': 'a' * 64, 'body.field': 'receiveCacheRetentionDays', 'body.value': value};
  test('retention input accepts exact signed JSON integer values and encodes typed JSON', () {
    for (final days in [-2, -1, 0, 1, 7, 30, 3650]) {
      final form = values('$days');
      expect(operation.valid(form), true);
      expect(operation.body(form)!['value'], days);
      expect(operation.body(form)!['value'], isA<int>());
      final request = jsonDecode(operation.request(form, 'TOKEN')) as Map;
      expect(request['body']['value'], days);
      expect(request['body']['field'], 'receiveCacheRetentionDays');
      expect(operation.body(form, placeholders: true)!['value'], days);
    }
  });
  test('booleans, JSON strings, fractions, exponent, malformed values and out-of-range inputs are rejected', () {
    for (final value in [
      '',
      'true',
      'false',
      'null',
      '"7"',
      '7.0',
      '1e1',
      '-3',
      '3651',
      '999999999999999999999999999999999999',
      '+7',
      ' 7',
      '7 ',
      '07',
      'NaN',
    ]) {
      expect(operation.valid(values(value)), false, reason: value);
    }
    expect(operation.valid({...values('7'), 'body.version': 'old'}), false);
  });
  test('existing setting enum and boolean forms are not widened by integer support', () {
    for (final field in ['enableAnimations', 'autoFinish', 'createChecksums', 'verifyChecksums']) {
      expect(operation.valid({...values('7'), 'body.field': field}), false);
      final form = {...values('false'), 'body.field': field};
      expect(operation.valid(form), true);
      expect(operation.body(form)!['value'], false);
    }
    expect(operation.valid({...values('dark'), 'body.field': 'theme'}), true);
    expect(operation.valid({...values('7'), 'body.field': 'theme'}), false);
    expect(operation.valid({...values('zh-CN'), 'body.field': 'locale'}), true);
    expect(operation.valid({...values('Legna'), 'body.field': 'alias'}), true);
    expect(operation.valid({...values('7'), 'body.field': 'unknownField'}), false);
  });
  test('all copied client examples keep the retention value numeric without leaking credentials', () {
    final examples = operation.examples(Uri.parse('http://127.0.0.1:53317'), values('-1'));
    expect(examples.keys, containsAll(['cURL (sh)', 'JavaScript', 'Python']));
    for (final example in examples.values) {
      expect(example, contains('receiveCacheRetentionDays'));
      expect(example, contains('-1'));
      expect(example, isNot(contains('"value":"-1"')));
      expect(example, contains('settings.write'));
    }
  });
  test('four locale confirmation copy explains integer retention and no immediate deletion', () {
    for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      final copy = ApiTransferStrings(locale);
      expect(copy.field('value'), contains('3650'));
      expect(copy.action('updateSettings'), contains('receiveCacheRetentionDays'));
      expect(copy.action('updateSettings'), contains('3650'));
    }
  });
}
