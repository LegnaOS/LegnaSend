import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';

const id = '11111111-1111-4111-8111-111111111111';
void main() {
  for (final language in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    test('native task and workspace send console contracts $language', () {
      final catalog = ApiCatalog.parse(File('assets/api_docs/integration-openapi-$language.json').readAsStringSync());
      final native = catalog.operations.singleWhere((o) => o.id == 'controlNativeTask');
      final values = {'taskId': id, 'body.epoch': id, 'body.version': id, 'body.action': 'cancel'};
      expect(native.isMutation, true);
      expect(native.isNativeTask, true);
      expect(native.group, 'transfers');
      expect(native.valid(values), true);
      expect(native.valid({...values, 'body.action': 'pause'}), false);
      final request = jsonDecode(native.request(values, 'TOKEN'));
      expect(request['body'], {'epoch': id, 'version': id, 'action': 'cancel'});
      expect(request['parameters'], {'taskId': id});
      for (final example in native.examples(Uri.parse('http://127.0.0.1:53317'), values).values) {
        expect(example, contains('nativeTasks.control'));
        expect(example, contains('POST'));
      }
      final sourceEnd = catalog.operations.singleWhere((o) => o.id == 'retrySourceEndNotice');
      final noticeValues = {'noticeId': id, 'body.version': id, 'body.requestId': id};
      expect(sourceEnd.isMutation, true);
      expect(sourceEnd.hasRequestId, true);
      expect(sourceEnd.group, 'transfers');
      expect(sourceEnd.valid(noticeValues), true);
      expect(sourceEnd.valid({...noticeValues, 'body.version': 'old'}), false);
      expect(sourceEnd.body(noticeValues), {'version': id, 'requestId': id});
      final noticeRequest = jsonDecode(sourceEnd.request(noticeValues, 'TOKEN'));
      expect(noticeRequest['parameters'], {'noticeId': id});
      expect(noticeRequest['body'], {'version': id, 'requestId': id});
      for (final example in sourceEnd.examples(Uri.parse('http://127.0.0.1:53317'), noticeValues).values) {
        expect(example, contains('nativeTasks.control'));
        expect(example, contains('requestId'));
        expect(example, contains('/source-end/'));
      }
      expect(ApiTransferStrings(language).action('retrySourceEndNotice'), isNotEmpty);
      final workspace = catalog.operations.singleWhere((o) => o.id == 'sendWorkspaceFiles');
      final files = jsonEncode([
        {'id': 'Zm9v', 'version': '"abc"'},
      ]);
      final send = {'workspaceId': id, 'body.instanceId': id, 'body.generation': '4', 'body.deviceId': id, 'body.requestId': id, 'body.files': files};
      expect(workspace.isMutation, true);
      expect(workspace.hasRequestId, true);
      expect(workspace.valid(send), true);
      expect(jsonDecode(workspace.request(send, 'TOKEN'))['body']['files'][0]['version'], '"abc"');
      expect(workspace.valid({...send, 'body.files': 'not-json'}), false);
      expect(workspace.valid({...send, 'body.files': '[]'}), false);
      expect(
        workspace.valid({
          ...send,
          'body.files': jsonEncode(List.filled(129, {'id': 'Zm9v', 'version': '"abc"'})),
        }),
        false,
      );
      for (final example in workspace.examples(Uri.parse('http://127.0.0.1:53317'), send).values) {
        expect(example, contains('files.read'));
        expect(example, contains('requestId'));
      }
      final strings = ApiTransferStrings(language);
      expect(strings.nativeOperation, isNotEmpty);
      expect(strings.action('sendWorkspaceFiles'), isNotEmpty);
      expect(strings.field('files'), isNot('files'));
    });
  }
}
