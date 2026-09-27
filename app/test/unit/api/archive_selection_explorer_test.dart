import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';

void main() {
  const id = '11111111-1111-4111-8111-111111111111';
  final ids = List.generate(5000, (i) => '00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}');
  for (final language in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    test('large archive body and cancellation use $language contract and real console encoding', () {
      final catalog = ApiCatalog.parse(File('assets/api_docs/integration-openapi-$language.json').readAsStringSync());
      final prepare = catalog.operations.singleWhere((op) => op.id == 'prepareWorkspaceArchive');
      final fields = {'workspaceId': id, 'generation': '1', 'body.path': '', 'body.ids': jsonEncode(ids)};
      expect(prepare.isArchiveSelection, isTrue);
      expect(prepare.valid(fields), isTrue);
      final request = jsonDecode(prepare.request(fields, 'TOKEN')) as Map;
      expect((request['body'] as Map)['ids'], hasLength(5000));
      expect((request['body'] as Map)['path'], '');
      expect(
        prepare.valid({
          ...fields,
          'body.ids': jsonEncode([id, id]),
        }),
        isFalse,
      );
      expect(prepare.valid({...fields, 'body.path': '界' * 1366}), isFalse);
      final curl = prepare.examples(Uri.parse('http://127.0.0.1:53317'), fields)['cURL (sh)']!;
      expect(curl, contains('--data-binary'));
      expect(curl, contains('"ids":["FILE_ID"]'));
      expect(curl, contains('files.read'));
      final cancel = catalog.operations.singleWhere((op) => op.id == 'cancelWorkspaceArchive');
      expect(cancel.valid({'workspaceId': id, 'generation': '1', 'body.selection': id}), isTrue);
      final archive = catalog.operations.singleWhere((op) => op.id == 'downloadWorkspaceArchive');
      expect(archive.valid({'workspaceId': id, 'generation': '1', 'selection': id}), isTrue);
      expect(
        archive.valid({
          'workspaceId': id,
          'generation': '1',
          'selection': id,
          'ids': jsonEncode([id]),
        }),
        isFalse,
      );
      expect(ApiTransferStrings(language).field('ids'), isNot('ids'));
    });
  }
}
