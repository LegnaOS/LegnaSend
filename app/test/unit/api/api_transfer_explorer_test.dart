import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';

const device = 'a3c0255f-42bd-4c85-912b-551b8eae1367';
const version = 'acd0255f-42bd-4c85-912b-551b8eae1367';
const requestId = 'ebd0255f-42bd-4c85-912b-551b8eae1367';
Map<String, dynamic> transferOperationFixture(String id) => {
  'operationId': id,
  'summary': id,
  'parameters': [
    if (['getDevice', 'getTransfer', 'cancelTransfer', 'retryTransfer', 'removeTransfer'].contains(id))
      {
        'name': id == 'getDevice' ? 'deviceId' : 'transferId',
        'in': 'path',
        'required': true,
        'schema': {'type': 'string', 'format': 'uuid'},
      },
  ],
};
ApiOperation op(String id) =>
    ApiOperation(id == 'sendSelection' ? '/transfers/send' : '/transfers/{transferId}/retry', 'POST', transferOperationFixture(id));
void main() {
  test('explicit outgoing route is optional UUID in request and example', () {
    final send = op('sendSelection');
    final values = {'body.deviceId': device, 'body.selectionVersion': version, 'body.requestId': requestId, 'body.localRouteId': requestId};
    expect(send.valid(values), isTrue);
    expect(send.body(values)!['localRouteId'], requestId);
    expect(send.body(values, placeholders: true)!['localRouteId'], 'LOCAL_ROUTE_ID');
    expect(send.valid({...values, 'body.localRouteId': 'en0'}), isFalse);
    for (final language in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      expect(ApiTransferStrings(language).field('localRouteId'), isNot('localRouteId'));
    }
  });

  test('catalog exposes ten fixed transfer operations and rejects arbitrary POSTs', () {
    final operations = {
      'listDevices': 'get',
      'getDevice': 'get',
      'scanDevices': 'post',
      'getSendSelection': 'get',
      'sendSelection': 'post',
      'listTransfers': 'get',
      'getTransfer': 'get',
      'cancelTransfer': 'post',
      'retryTransfer': 'post',
      'removeTransfer': 'post',
    };
    final catalog = ApiCatalog.parse(
      jsonEncode({
        'paths': {
          for (final entry in operations.entries) '/fixture/${entry.key}': {entry.value: transferOperationFixture(entry.key)},
          '/arbitrary': {
            'post': {'operationId': 'deleteEverything'},
          },
        },
        'components': {'schemas': {}},
      }),
    );
    expect(catalog.operations, hasLength(10));
    expect(catalog.operations.every((op) => op.isTransfer && op.group == 'transfers'), isTrue);
    final get = catalog.operations.singleWhere((op) => op.id == 'getDevice');
    expect(get.valid({'deviceId': device}), isTrue);
    expect(get.valid({'deviceId': 'http://unapproved'}), isFalse);
    expect(get.isMutation, isFalse);
  });
  test('send validates UUIDs and uses body placeholders without query IDs', () {
    final send = op('sendSelection');
    final values = {'body.deviceId': device, 'body.selectionVersion': version, 'body.requestId': requestId};
    expect(send.valid(values), isTrue);
    expect(send.isMutation, isTrue);
    final actual = jsonDecode(send.request(values, 'SECRET')) as Map;
    expect(actual['body'], {'deviceId': device, 'selectionVersion': version, 'requestId': requestId});
    expect(actual['parameters'], isEmpty);
    expect(send.uri(Uri.parse('http://127.0.0.1:53317'), values).query, isEmpty);
    for (final example in send.examples(Uri.parse('http://127.0.0.1:53317'), values).values) {
      expect(example, contains('REQUEST_ID'));
      expect(example, contains('DEVICE_ID'));
      expect(example, isNot(contains(device)));
      expect(example, isNot(contains('SECRET')));
    }
    for (final key in values.keys) {
      expect(send.valid({...values}..remove(key)), isFalse);
      expect(send.valid({...values, key: 'not-a-uuid'}), isFalse);
    }
    expect(send.valid({...values, 'body.channelId': device}), isTrue);
    expect(send.valid({...values, 'body.channelId': 'http://target'}), isFalse);
  });
  test('retry and bodyless controls preserve fixed console operations', () {
    final result = jsonDecode(op('retryTransfer').request({'transferId': device, 'body.requestId': requestId}, 'TOKEN'));
    expect(result['body'], {'requestId': requestId});
    for (final example in op('retryTransfer').examples(Uri.parse('http://127.0.0.1'), {'transferId': device, 'body.requestId': requestId}).values) {
      expect(example, contains('ALL original task files'));
      expect(example, contains('already completed files'));
      expect(example, isNot(contains('incomplete files')));
    }
    for (final name in ['scanDevices', 'cancelTransfer', 'removeTransfer']) {
      final control = ApiOperation('/devices/scan', 'POST', transferOperationFixture(name));
      expect(control.isTransferMutation, isTrue);
      expect(jsonDecode(control.request({'transferId': device}, 'TOKEN')), isNot(contains('body')));
    }
  });
  test('thirteen global key scopes roundtrip and are excluded from anonymous policy', () {
    final scopes = ApiScope.values.where((s) => s.requiresGlobal).toList();
    expect(scopes.toSet(), {
      ApiScope.devicesRead,
      ApiScope.devicesScan,
      ApiScope.transfersRead,
      ApiScope.transfersSend,
      ApiScope.transfersControl,
      ApiScope.cacheRead,
      ApiScope.cacheClean,
      ApiScope.settingsRead,
      ApiScope.settingsWrite,
      ApiScope.keysManage,
      ApiScope.requestsManage,
      ApiScope.nativeTasksRead,
      ApiScope.nativeTasksControl,
    });
    expect(ApiGrant.fromJson(ApiGrant(scopes: scopes, workspaces: ['*']).toJson()).scopes, scopes);
    for (final scope in scopes) {
      expect(
        () => ApiPolicy(
          anonymousGrant: ApiGrant(scopes: [scope], workspaces: ['*']),
        ),
        throwsFormatException,
      );
      expect(scope.allowsAnonymous, isFalse);
    }
  });
  test('localized hints cover EN simplified traditional and English fallback', () {
    for (final lang in ['en', 'zh-CN', 'zh-TW', 'zh-HK', 'fr']) {
      final text = ApiTransferStrings(lang);
      expect(text.hint, contains('*'));
      expect(text.action('retryTransfer'), contains('LocalSend'));
      expect(text.action('retryTransfer'), contains(lang.startsWith('zh') ? (lang == 'zh-CN' ? '全部文件' : '全部檔案') : 'All files'));
      expect(text.action('retryTransfer'), isNot(contains('Incomplete files')));
      for (final scope in ApiScope.values.where((s) => s.requiresGlobal)) {
        expect(text.scope(scope), isNot(scope.wire));
      }
    }
    expect(const ApiTransferStrings('fr').hint, const ApiTransferStrings('en').hint);
  });
}
