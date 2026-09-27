import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/api/source_end_management.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:uuid/uuid.dart';

void main() {
  const uuid = Uuid();
  final id = uuid.v4(), version = uuid.v4(), requestId = uuid.v4();
  Map<String, dynamic> input(String operation) => {
    'operation': operation,
    'principal': uuid.v4(),
    'workspaces': ['*'],
  };
  test('list claims before redacted host state and never exposes private fields', () async {
    var claimed = false;
    final host = SourceEndManagement(
      read: () {
        expect(claimed, true);
        return {'notices': [], 'truncated': false};
      },
      retry: (_, _, _) async => {},
    );
    final result = jsonDecode(
      await host.execute(
        request: jsonEncode(input('nativeTasks.sourceEndList')),
        claim: () async {
          claimed = true;
          return true;
        },
      ),
    );
    expect(result['status'], 200);
    expect(result['body'], {'notices': [], 'truncated': false});
  });
  test('invalid UUID retry rejected before claim', () async {
    var claims = 0;
    final host = SourceEndManagement(read: () => {}, retry: (_, _, _) async => {});
    final body = {
      ...input('nativeTasks.sourceEndRetry'),
      'noticeId': 'invalid',
      'body': {'version': version, 'requestId': requestId},
    };
    final result = jsonDecode(
      await host.execute(
        request: jsonEncode(body),
        claim: () async {
          claims++;
          return true;
        },
      ),
    );
    expect(result['status'], 400);
    expect(claims, 0);
  });
  test('lost action claim never dispatches cleanup retry', () async {
    var retries = 0;
    final host = SourceEndManagement(
      read: () => {},
      retry: (_, _, _) async {
        retries++;
        return {};
      },
    );
    final body = {
      ...input('nativeTasks.sourceEndRetry'),
      'noticeId': id,
      'body': {'version': version, 'requestId': requestId},
    };
    final result = jsonDecode(await host.execute(request: jsonEncode(body), claim: () async => false));
    expect(result['status'], 409);
    expect(retries, 0);
  });
  test('retry conveys exact optimistic revision and storage error is fixed', () async {
    final host = SourceEndManagement(
      read: () => {},
      retry: (i, v, r) async {
        expect((i, v, r), (id, version, requestId));
        throw const SourceEndStorageException('commitUnknown');
      },
    );
    final body = {
      ...input('nativeTasks.sourceEndRetry'),
      'noticeId': id,
      'body': {'version': version, 'requestId': requestId},
    };
    final result = jsonDecode(await host.execute(request: jsonEncode(body), claim: () async => true));
    expect(result['status'], 503);
    expect(result['body']['error']['code'], 'source_end_storage_failed');
  });
}
