import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';

ApiParameter parameter(Map<String, Object> schema, {String name = 'value', bool required = false}) =>
    ApiParameter({'name': name, 'in': 'query', 'required': required, 'schema': schema});
ApiOperation stateOperation({int budget = 24576}) => ApiOperation('/workspaces/{workspaceId}/state', 'GET', {
  'operationId': 'getWorkspaceState',
  'x-legnasend-max-query-bytes': budget,
  'parameters': [
    {
      'name': 'workspaceId',
      'in': 'path',
      'required': true,
      'schema': {'type': 'string', 'maxLength': 4096, 'x-legnasend-max-utf8-bytes': 4096},
    },
    {
      'name': 'generation',
      'in': 'query',
      'required': true,
      'schema': {'type': 'integer', 'minimum': 1, 'x-legnasend-max-utf8-bytes': 4096},
    },
    {
      'name': 'path',
      'in': 'query',
      'required': false,
      'schema': {'type': 'string', 'maxLength': 4096, 'x-legnasend-max-utf8-bytes': 4096},
    },
    {
      'name': 'ids',
      'in': 'query',
      'required': false,
      'schema': {
        'type': 'string',
        'maxLength': 8192,
        'pattern': r'^(?:[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+){0,63})?$',
        'x-legnasend-max-utf8-bytes': 8192,
        'description': 'At most 8192 bytes',
      },
    },
  ],
});
void main() {
  test('state IDs accept 4096 and 8192 bytes while ordinary parameters keep 4096', () {
    final operation = stateOperation();
    final ids = operation.parameters.last;
    expect(ids.inputLimit, 8192);
    expect(ids.utf8Limit, 8192);
    expect(ids.description, contains('8192'));
    for (final bad in ['../path', 'https://host', '你好', 'a,,b', List.filled(65, 'a').join(',')]) {
      expect(ids.valid(bad), false);
    }
    for (final count in [4096, 8192]) {
      final values = {'workspaceId': 'workspace', 'generation': '1', 'ids': 'a' * count};
      expect(operation.valid(values), true);
      expect(jsonDecode(operation.request(values, 'TOKEN'))['parameters']['ids'], hasLength(count));
    }
    expect(operation.isMutation, false);
    expect(operation.method, 'GET');
    expect(operation.valid({'workspaceId': 'workspace', 'generation': '1', 'ids': 'a' * 8193}), false);
    final ordinary = parameter({'type': 'string', 'maxLength': 4096, 'x-legnasend-max-utf8-bytes': 4096});
    expect(ordinary.valid('a' * 4096), true);
    expect(ordinary.valid('a' * 4097), false);
    expect(ordinary.valid('a' * 8192), false);
  });
  test('schema scalar limits are distinct from UTF16, graphemes and UTF8 bytes', () {
    final filter = parameter({'type': 'string', 'maxLength': 256, 'x-legnasend-max-utf8-bytes': 4096});
    expect(filter.valid('😀' * 256), true);
    expect(filter.valid('😀' * 257), false);
    expect(filter.valid('e\u0301' * 128), true);
    expect(filter.valid('e\u0301' * 129), false);
    final path = parameter({'type': 'string', 'maxLength': 4096, 'x-legnasend-max-utf8-bytes': 4096});
    expect(path.valid('😀' * 1024), true);
    expect(path.valid('😀' * 1025), false);
    expect(path.valid('界' * 1365 + 'a'), true);
    expect(path.valid('界' * 1366), false);
    for (final control in ['\u0000', '\u001f', '\u007f', '\u0085', '\u009f', '\ud800']) {
      expect(path.valid('x${control}y'), false);
    }
  });
  test('minLength pattern enum and existing numeric constraints compose with byte budgets', () {
    final id = parameter({'type': 'string', 'minLength': 2, 'maxLength': 5, 'pattern': '^[a-z]+\$', 'x-legnasend-max-utf8-bytes': 5}, required: true);
    expect(id.valid(''), false);
    expect(id.valid('a'), false);
    expect(id.valid('abc'), true);
    expect(id.valid('abcdef'), false);
    expect(id.valid('ab1'), false);
    expect(parameter({'type': 'string', 'pattern': '['}).valid('abc'), false);
    expect(parameter({'type': 'string', 'maxLength': 0}).valid('a'), false);
    final number = parameter({'type': 'integer', 'minimum': 1, 'maximum': 100});
    expect(number.valid('100'), true);
    expect(number.valid('101'), false);
    expect(number.valid('-1'), false);
    final selected = parameter({
      'type': 'string',
      'enum': ['yes', 'no'],
      'maxLength': 2,
    });
    expect(selected.valid('yes'), false);
    expect(selected.valid('no'), true);
  });
  test('percent encoded query budget is bounded separately and cannot expand unrelated operations', () {
    final state = stateOperation();
    final values = {'workspaceId': 'workspace', 'generation': '1', 'ids': 'a' * 8192, 'path': '%' * 4096};
    expect(state.valid(values), true);
    expect(state.uri(Uri.parse('http://127.0.0.1:53317'), values).query.length, greaterThan(8192));
    expect(stateOperation(budget: 8192).valid(values), false);
    expect(stateOperation(budget: 8192).valid({'workspaceId': 'workspace', 'generation': '1', 'path': '%' * 3000}), false);
    expect(stateOperation(budget: 8192).valid({'workspaceId': 'workspace', 'generation': '1', 'path': '~' * 3000}), false);
    expect(stateOperation(budget: 8192).valid({'workspaceId': 'workspace', 'generation': '1', 'path': '*' * 3000}), false);
    expect(state.parameters.last.valid('a' * 24576), false);
  });
}
