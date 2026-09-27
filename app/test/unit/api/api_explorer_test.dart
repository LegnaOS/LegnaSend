import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';

void main() {
  ApiCatalog catalog([String locale = 'en']) => ApiCatalog.parse(File('assets/api_docs/integration-openapi-$locale.json').readAsStringSync());
  test('all localized contracts expose reads, content HEAD and explicit upload and persisted management POST operations', () {
    final ids = catalog().operations.map((op) => op.id).toSet();
    expect(ids.length, 45);
    expect(ids, containsAll(['listKeys', 'createKey', 'manageKey', 'getKeyReceipt', 'clearRequests']));
    for (final id in ['createKey', 'manageKey', 'clearRequests']) {
      expect(catalog().operations.singleWhere((op) => op.id == id).method, 'POST');
      expect(catalog().operations.singleWhere((op) => op.id == id).isMutation, isTrue);
    }
    expect(catalog().operations.singleWhere((op) => op.id == 'createWorkspace').method, 'POST');
    expect(catalog().operations.singleWhere((op) => op.id == 'listApprovedWorkspaceSources').group, 'workspaces');
    expect(catalog().operations.singleWhere((op) => op.id == 'manageWorkspace').method, 'POST');
    expect(catalog().operations.singleWhere((op) => op.id == 'listManagedWorkspaces').group, 'workspaces');
    expect(catalog().operations.singleWhere((op) => op.id == 'uploadFile').method, 'POST');
    for (final locale in ['zh-CN', 'zh-TW', 'zh-HK']) {
      expect(catalog(locale).operations.map((op) => op.id).toSet(), ids);
    }
    expect(catalog().operations.singleWhere((op) => op.id == 'listRequests').group, 'history');
  });
  test('required, numeric boundaries and enum parameters reject invalid values', () {
    final files = catalog().operations.singleWhere((op) => op.id == 'listFiles');
    expect(files.valid({}), false);
    expect(files.valid({'workspaceId': 'id', 'generation': '1'}), true);
    expect(files.valid({'workspaceId': 'id', 'generation': '0'}), false);
    final requests = catalog().operations.singleWhere((op) => op.id == 'listRequests');
    expect(requests.valid({'limit': '101'}), false);
    expect(requests.valid({'limit': '-1'}), false);
    expect(catalog().operations.singleWhere((op) => op.id == 'getOpenApi').valid({'lang': 'other'}), false);
  });
  test('document upload parent survives localized contract, request and code examples', () {
    for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      final upload = catalog(locale).operations.singleWhere((op) => op.id == 'uploadFile');
      final values = {'workspaceId': 'workspace', 'generation': '1', 'path': 'Empty', 'directory': 'true', 'parent': 'opaque-parent'};
      expect(upload.valid(values), true);
      expect(upload.inputParameters.any((p) => p.name == 'Content-Length'), false);
      values['Content-Length'] = '999999999';
      expect(upload.valid(values), true);
      final fileValues = {...values, 'directory': 'false'};
      expect(upload.valid(fileValues), true);
      expect(upload.request(fileValues, 'TOKEN', uploadSource: {'uploadPath': '/fixture.txt'}), isNot(contains('999999999')));
      expect(upload.uri(Uri.parse('http://host:53317'), values).queryParameters['parent'], 'opaque-parent');
      expect(upload.request(values, 'TOKEN'), contains('opaque-parent'));
      for (final example in upload.examples(Uri.parse('http://host:53317'), values).values) {
        expect(example, contains('parent=opaque-parent'));
        expect(example, isNot(contains('999999999')));
      }
    }
  });
  test('document send mode requires issued IDs and never fabricates versions', () {
    const id = '01234567-89ab-4cde-8123-456789abcdef';
    for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      final op = catalog(locale).operations.singleWhere((op) => op.id == 'sendWorkspaceFiles');
      final values = {
        'workspaceId': id,
        'body.instanceId': id,
        'body.generation': '1',
        'body.deviceId': id,
        'body.requestId': id,
        'body.sourceMode': 'documentSnapshot',
        'body.files': jsonEncode([
          {'id': id},
        ]),
      };
      expect(op.valid(values), true);
      expect(op.bodyFields(values), contains('sourceMode'));
      final body = jsonDecode(op.request(values, 'TOKEN'))['body'];
      expect(body['sourceMode'], 'documentSnapshot');
      expect(body['files'], [
        {'id': id},
      ]);
      for (final code in op.examples(Uri.parse('http://host:53317'), values).values) {
        expect(code, contains('documentSnapshot'));
        expect(code, isNot(contains('ETAG')));
      }
      expect(
        op.valid({
          ...values,
          'body.files': jsonEncode([
            {'id': id, 'version': '"fake"'},
          ]),
        }),
        false,
      );
      expect(op.valid({...values, 'body.sourceMode': 'unknown'}), false);
      expect(op.valid({...values, 'body.sourceMode': ''}), false);
      expect(
        op.valid({
          ...values,
          'body.files': jsonEncode([
            {'id': 'content://outside'},
          ]),
        }),
        false,
      );
      expect(
        op.valid({
          ...values,
          'body.files': jsonEncode([
            {'id': id},
            {'id': id},
          ]),
        }),
        false,
      );
      final filesystem = {
        ...values,
        'body.sourceMode': '',
        'body.files': jsonEncode([
          {'id': 'ZmlsZQ', 'version': '"etag"'},
        ]),
      };
      expect(op.valid(filesystem), true);
      expect(op.body(filesystem)!.containsKey('sourceMode'), false);
    }
  });
  test('paths and queries encode literal values; credentials stay out of examples', () {
    final files = catalog().operations.singleWhere((op) => op.id == 'listFiles');
    final values = {'workspaceId': 'a/b', 'generation': '1', 'path': '目录 &/%#'};
    final uri = files.uri(Uri.parse('http://127.0.0.1:54444'), values);
    expect(uri.pathSegments[5], 'a/b');
    expect(uri.queryParameters['path'], values['path']);
    final request = jsonDecode(files.request(values, 'secret'));
    expect(request['token'], 'secret');
    for (final example in files.examples(Uri.parse('http://127.0.0.1:54444'), values).values) {
      expect(example, isNot(contains('secret')));
      expect(example, contains('TOKEN'));
    }
    final head = catalog().operations.singleWhere((op) => op.id == 'headContent');
    final parsed = jsonDecode(head.request({'workspaceId': 'a', 'fileId': 'b', 'generation': '1'}, ''));
    expect(parsed['operation'], 'getContent');
    expect(parsed['head'], true);
  });
  test('display chunks bound hostile single lines and preserve Unicode', () {
    final text = '🙂\n${'a' * 2045}🙂${'字' * 30000}';
    final chunks = apiDisplayChunks(text);
    expect(chunks.join(), text);
    expect(chunks.every((s) => s.length <= 2048), true);
    expect(chunks.every((s) => !RegExp(r'[\uD800-\uDBFF]$').hasMatch(s)), true);
  });
}
