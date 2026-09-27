import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_management_strings.dart';

Map<String, dynamic> managementOperationFixture() => {
  'operationId': 'manageWorkspace',
  'summary': 'Manage workspace',
  'parameters': [
    {
      'name': 'workspaceId',
      'in': 'path',
      'required': true,
      'schema': {'type': 'string'},
    },
    {
      'name': 'generation',
      'in': 'query',
      'required': true,
      'schema': {'type': 'integer', 'minimum': 1},
    },
    {
      'name': 'action',
      'in': 'query',
      'required': true,
      'schema': {
        'type': 'string',
        'enum': ['update', 'enable', 'disable', 'validate', 'destroy', 'configure', 'password'],
      },
    },
    {
      'name': 'name',
      'in': 'query',
      'schema': {'type': 'string'},
    },
    {
      'name': 'visible',
      'in': 'query',
      'schema': {'type': 'boolean'},
    },
    {
      'name': 'allowUpload',
      'in': 'query',
      'schema': {'type': 'boolean'},
    },
  ],
  'responses': {
    '200': {'description': 'Completed'},
    '409': {'description': 'Stale generation'},
    '504': {'description': 'Unknown outcome'},
  },
};

void main() {
  ApiOperation operation() => ApiOperation('/workspaces/{workspaceId}/manage', 'POST', managementOperationFixture());
  const base = {'workspaceId': 'fixture', 'generation': '7', 'action': 'update'};
  test('management needs exact action and generation and update contains an actual change', () {
    final op = operation();
    expect(op.isMutation, true);
    expect(op.isManagement, true);
    expect(op.isUpload, false);
    expect(op.valid(base), false);
    expect(op.valid({...base, 'name': ''}), false);
    expect(op.valid({...base, 'name': '   '}), false);
    expect(op.valid({...base, 'name': '新名称'}), true);
    expect(op.valid({...base, 'visible': 'false'}), true);
    expect(op.valid({...base, 'allowUpload': 'true'}), true);
    expect(op.valid({...base, 'action': ''}), false);
    expect(op.valid({...base, 'generation': '0', 'name': 'name'}), false);
    expect(op.valid({...base, 'name': '字' * 161}), false);
    expect(op.valid({...base, 'name': '字' * 160}), true);
    for (final action in ['enable', 'disable', 'validate', 'destroy']) {
      expect(op.valid({...base, 'action': action}), true);
      expect(op.valid({...base, 'action': action, 'visible': 'false'}), false);
      expect(op.valid({...base, 'action': action, 'name': 'stale draft'}), false);
    }
  });
  test('omitted visibility and permission are never turned into false defaults', () {
    final fixture = managementOperationFixture();
    for (final parameter in fixture['parameters'] as List) {
      if (parameter['name'] == 'visible' || parameter['name'] == 'allowUpload') {
        parameter['schema'] = <String, dynamic>{...parameter['schema'] as Map<String, dynamic>, 'default': false};
      }
    }
    final op = ApiOperation('/workspaces/{workspaceId}/manage', 'POST', fixture);
    expect(op.defaults(), isEmpty);
    final request = jsonDecode(
      op.request({...base, 'name': 'Renamed'}, 'private-token', uploadSource: {'uploadPath': '/private/file', 'uploadSize': 5}),
    );
    expect(request['parameters'], {...base, 'name': 'Renamed'});
    expect(request.containsKey('uploadPath'), false);
    expect(request['head'], false);
    expect(request['token'], 'private-token');
  });
  test('management examples are bodyless POST with scoped credential placeholders and no file operations', () {
    final op = operation();
    final values = {...base, 'name': '中文 &%'};
    final examples = op.examples(Uri.parse('https://127.0.0.1:53317'), values);
    expect(examples['cURL (sh)'], contains('--request POST'));
    expect(examples['cURL (sh)'], contains("--data-binary ''"));
    expect(examples['JavaScript'], contains('body: new Uint8Array(0)'));
    expect(examples['Python'], contains('data=b""'));
    for (final example in examples.values) {
      expect(example, contains('workspaces.manage'));
      expect(example, contains('TOKEN'));
      expect(example, isNot(contains('FILE_PATH')));
      expect(example, isNot(contains('files[0]')));
    }
    expect(op.uri(Uri.parse('http://host:5'), values).queryParameters['name'], '中文 &%');
  });
  test('catalog admits explicit management POST and groups managed inventory with workspaces', () {
    final catalog = ApiCatalog.parse(
      jsonEncode({
        'paths': {
          '/managed-workspaces': {
            'get': {'operationId': 'listManagedWorkspaces'},
          },
          '/workspaces/{workspaceId}/manage': {'post': managementOperationFixture()},
          '/unsafe': {
            'post': {'operationId': 'unimplemented'},
          },
        },
        'components': {'schemas': {}},
      }),
    );
    expect(catalog.operations.map((op) => op.id), ['listManagedWorkspaces', 'manageWorkspace']);
    expect(catalog.operations.every((op) => op.group == 'workspaces'), true);
  });
  test('destroy and uncertain outcome copy distinguish metadata removal from deleting local files', () {
    for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      final text = ApiManagementStrings(locale);
      expect(text.destroy, isNotEmpty);
      expect(text.unknown, isNotEmpty);
      expect(text.review, isNotEmpty);
      expect(text.actionLabel('destroy'), isNot(text.actionLabel('disable')));
    }
    expect(const ApiManagementStrings('en').destroy, contains('not deleted'));
    expect(const ApiManagementStrings('en').unknown, contains('may already be saved'));
  });
}
