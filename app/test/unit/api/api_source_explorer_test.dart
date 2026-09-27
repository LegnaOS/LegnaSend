import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';

import 'api_management_explorer_test.dart' show managementOperationFixture;

void main() {
  const source = '11111111-1111-4111-8111-111111111111';
  final base = Uri.parse('http://127.0.0.1:53317');
  final manage = ApiOperation('/workspaces/{workspaceId}/manage', 'POST', managementOperationFixture());
  final create = ApiOperation('/managed-workspaces/create', 'POST', {'operationId': 'createWorkspace'});
  const params = {'workspaceId': source, 'generation': '1'};
  test('create uses a bounded body-only approved source and no path parameter', () {
    const values = {'body.sourceId': source, 'body.name': 'Private source name', 'body.slug': 'created', 'body.visible': 'false'};
    expect(create.valid(values), true);
    final request = jsonDecode(create.request(values, 'TOKEN'));
    expect(request['parameters'], isEmpty);
    expect(request['body'], {'sourceId': source, 'name': 'Private source name', 'slug': 'created', 'visible': false});
    expect(create.uri(base, values).query, isEmpty);
    for (final example in create.examples(base, values).values) {
      expect(example, isNot(contains(source)));
      expect(example, isNot(contains('Private source name')));
      expect(example, contains('SOURCE_ID'));
    }
    expect(create.valid({...values, 'body.sourceId': '/private/path'}), false);
    expect(create.valid({...values, 'body.slug': '../escape'}), false);
    expect(create.valid({...values, 'body.name': ''}), false);
  });
  test('configure and password never leak payload into URL or examples', () {
    final configure = {...params, 'action': 'configure', 'body.sourceId': '22222222-2222-4222-8222-222222222222', 'body.slug': 'new-route'};
    expect(manage.valid(configure), true);
    expect(manage.uri(base, configure).queryParameters, {'generation': '1', 'action': 'configure'});
    expect(jsonDecode(manage.request(configure, 'TOKEN'))['body'], {'sourceId': configure['body.sourceId'], 'slug': 'new-route'});
    expect(manage.valid({...params, 'action': 'configure'}), false);
    final password = {...params, 'action': 'password', 'body.password': 'Private-9381'};
    expect(manage.valid(password), true);
    expect(jsonDecode(manage.request(password, 'TOKEN'))['body'], {'password': 'Private-9381'});
    for (final example in manage.examples(base, password).values) {
      expect(example, isNot(contains('Private-9381')));
      expect(example, contains('PASSWORD'));
    }
    expect(manage.uri(base, password).toString(), isNot(contains('Private-9381')));
    expect(manage.valid({...password, 'body.clear': 'true'}), false);
    expect(manage.valid({...password, 'body.password': 'abc'}), false);
    expect(manage.valid({...password, 'body.password': 'a' * 129}), false);
    final clear = {...params, 'action': 'password', 'body.clear': 'true'};
    expect(manage.valid(clear), true);
    expect(jsonDecode(manage.request(clear, 'TOKEN'))['body'], {'clear': true});
  });
  test('new operations stay in the workspace catalog', () {
    final catalog = ApiCatalog.parse(
      jsonEncode({
        'components': {'schemas': {}},
        'paths': {
          '/approved-workspace-sources': {
            'get': {'operationId': 'listApprovedWorkspaceSources'},
          },
          '/managed-workspaces/create': {
            'post': {'operationId': 'createWorkspace'},
          },
        },
      }),
    );
    expect(catalog.operations.length, 2);
    expect(catalog.operations.every((op) => op.group == 'workspaces'), true);
  });
}
