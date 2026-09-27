import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_upload_source.dart';

void main() {
  final operation = ApiOperation('/workspaces/{workspaceId}/upload', 'POST', {
    'operationId': 'uploadFile',
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
        'name': 'path',
        'in': 'query',
        'required': true,
        'schema': {'type': 'string'},
      },
      {
        'name': 'directory',
        'in': 'query',
        'required': false,
        'schema': {'type': 'boolean', 'default': false},
      },
    ],
  });
  final values = {'workspaceId': 'abc', 'generation': '1', 'path': '目录/file %?.txt', 'directory': 'false'};
  test('upload request accepts picker metadata, never file bytes, and directory requests omit stale source', () {
    expect(operation.isUpload, true);
    expect(() => operation.request(values, 'secret'), throwsFormatException);
    final source = const ApiUploadSource(name: 'private-name', path: '/private/path.bin', size: 5000000000);
    final request = jsonDecode(operation.request(values, 'secret', uploadSource: source.requestFields));
    expect(request['operation'], 'uploadFile');
    expect(request['uploadPath'], source.path);
    expect(request['uploadSize'], source.size);
    expect(request['head'], false);
    final directory = jsonDecode(operation.request({...values, 'directory': 'true'}, 'secret', uploadSource: source.requestFields));
    expect(directory.containsKey('uploadPath'), false);
    expect(directory.containsKey('uploadSize'), false);
    expect(operation.valid({...values, 'directory': 'yes'}), false);
  });
  test('Android picker content URI remains a URI until the trusted worker opens it', () {
    const source = ApiUploadSource(name: 'provider', path: 'content://provider/document/opaque%2Fid', size: 17);
    expect(source.requestFields, {'uploadUri': source.path, 'uploadSize': 17});
    expect(source.requestFields.containsKey('uploadFd'), false);
  });
  test('upload examples use exact POST and streaming placeholders without selected path or secret', () {
    final examples = operation.examples(Uri.parse('https://127.0.0.1:53317'), values);
    expect(examples['cURL (sh)'], contains('--request POST'));
    expect(examples['cURL (sh)'], contains('--upload-file FILE_PATH'));
    expect(examples['JavaScript'], contains('files[0]'));
    expect(examples['JavaScript'], contains('body,'));
    expect(examples['Python'], contains('data=source'));
    expect(examples['Python'], contains('os.fstat(source.fileno()).st_size'));
    expect(examples['Python'], contains('response.read(262144)'));
    for (final source in examples.values) {
      expect(source, isNot(contains('/private/path.bin')));
      expect(source, isNot(contains('secret')));
      expect(source, contains('TOKEN'));
    }
    final uri = operation.uri(Uri.parse('http://host:123'), values);
    expect(uri.queryParameters['path'], values['path']);
  });
  test('empty-directory examples use zero-byte bodies and no file picker or local file read', () {
    final examples = operation.examples(Uri.parse('http://host:123'), {...values, 'directory': 'true'});
    expect(examples['cURL (sh)'], contains("--data-binary ''"));
    expect(examples['JavaScript'], contains('new Uint8Array(0)'));
    expect(examples['Python'], contains('data=b""'));
    for (final source in examples.values) {
      expect(source, isNot(contains('FILE_PATH')));
      expect(source, isNot(contains('files[0]')));
    }
  });
  test('catalog admits the implemented upload POST but not unrelated write operations', () {
    final catalog = ApiCatalog.parse(
      jsonEncode({
        'paths': {
          '/file': {
            'post': {'operationId': 'uploadFile'},
          },
          '/admin': {
            'post': {'operationId': 'deleteEverything'},
          },
        },
        'components': {'schemas': {}},
      }),
    );
    expect(catalog.operations.map((op) => op.id), ['uploadFile']);
  });
}
