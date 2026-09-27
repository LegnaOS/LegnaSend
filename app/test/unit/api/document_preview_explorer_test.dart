import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';

void main() {
  const id = '11111111-1111-4111-8111-111111111111';
  for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    test('document preview controls and archive HEAD use the real $locale contract', () {
      final catalog = ApiCatalog.parse(File('assets/api_docs/integration-openapi-$locale.json').readAsStringSync());
      for (final name in ['prepareDocumentPreview', 'closeDocumentPreview']) {
        final operation = catalog.operations.singleWhere((op) => op.id == name);
        final field = name == 'prepareDocumentPreview' ? 'id' : 'lease';
        final values = {'workspaceId': id, 'generation': '1', 'body.$field': id};
        expect(operation.isPreviewLease, isTrue);
        expect(operation.isMutation, isTrue);
        expect(operation.valid(values), isTrue);
        expect(jsonDecode(operation.request(values, 'TOKEN'))['body'], {field: id});
        expect(operation.valid({...values, 'body.$field': '/arbitrary/path'}), isFalse);
        expect(ApiTransferStrings(locale).field(field), isNot(field));
        final curl = operation.examples(Uri.parse('http://127.0.0.1:53317'), values)['cURL (sh)']!;
        expect(curl, contains('--data-binary'));
        expect(curl, contains('files.read'));
        expect(curl, contains('"$field"'));
      }
      final head = catalog.operations.singleWhere((op) => op.id == 'headWorkspaceArchive');
      final values = {
        'workspaceId': id,
        'generation': '1',
        'ids': jsonEncode([id]),
      };
      expect(head.valid(values), isTrue);
      expect(jsonDecode(head.request(values, 'TOKEN'))['operation'], 'downloadWorkspaceArchive');
      expect(
        head.valid({
          ...values,
          'ids': jsonEncode([id, id]),
        }),
        isFalse,
      );
    });
  }
}
