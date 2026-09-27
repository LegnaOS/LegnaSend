import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/directory_write_provider.dart';

String id(int n) => '11111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';
Map<String, dynamic> request(int n, {String operation = 'begin', int attempt = 100, int owner = 200, bool directory = false}) => {
  'version': 1,
  'requestId': id(n),
  'op': operation,
  'owner': id(owner),
  'workspaceId': id(300),
  'generation': 1,
  'tree': 'content://provider/tree/root',
  'attemptId': id(attempt),
  if (operation == 'begin') ...{'parent': '', 'path': directory ? 'folder' : 'folder/file.bin', 'size': directory ? 0 : 100, 'directory': directory},
  if (operation != 'begin') ...{'transactionId': id(attempt + 1000), 'lease': 'lease-$attempt'},
  if (operation == 'publish') ...{'coreAttemptId': id(attempt), 'size': directory ? 0 : 100, 'sha256': directory ? '' : 'a' * 64},
};
Map<String, Object?> begun({int attempt = 100, bool directory = false}) => {
  'payload': jsonEncode({'version': 1, 'transactionId': id(attempt + 1000), 'lease': 'lease-$attempt'}),
  if (!directory) ...{'cacheFd': 40, 'stagingFd': 41},
};

class Replies {
  final calls = <Map<String, Object?>>[];
  bool accepted = true;
  Future<bool> call({required String requestId, String? payload, int? cacheDescriptor, int? stagingDescriptor, String? error}) async {
    calls.add({'id': requestId, 'payload': payload, 'cache': cacheDescriptor, 'staging': stagingDescriptor, 'error': error});
    return accepted;
  }
}

Future<void> handle(DirectoryWriteProvider provider, Map<String, dynamic> value) => provider.handle(value['requestId'] as String, jsonEncode(value));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual private channel uses scoped request and transfers both descriptors exactly once', () async {
    const channel = MethodChannel('org.localsend.localsend_app/localsend');
    final replies = Replies();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return begun();
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final provider = DirectoryWriteProvider(reply: replies.call, isCurrent: () => true, android: true);
    await handle(provider, request(1));
    expect(calls.single.method, 'workspaceDocumentWrite');
    expect(calls.single.arguments, {'request': jsonEncode(request(1))});
    expect(replies.calls.single['cache'], 40);
    expect(replies.calls.single['staging'], 41);
    expect(provider.transactionCount, 1);
  });
  test('late begin after close consumes dual FDs before scoped release and never transfers into replacement', () async {
    final replies = Replies(), gate = Completer<Object?>();
    final order = <String>[];
    final provider = DirectoryWriteProvider(
      android: true,
      isCurrent: () => true,
      reply: ({required requestId, payload, cacheDescriptor, stagingDescriptor, error}) async {
        if (cacheDescriptor != null) order.add('fd-closed');
        return replies.call(
          requestId: requestId,
          payload: payload,
          cacheDescriptor: cacheDescriptor,
          stagingDescriptor: stagingDescriptor,
          error: error,
        );
      },
      invoke: (raw) async {
        final value = jsonDecode(raw);
        if (value['op'] == 'begin') return gate.future;
        order.add(value['op'] as String);
        return {'payload': '{"version":1}'};
      },
    );
    final operation = handle(provider, request(1));
    await provider.close();
    expect(provider.pendingCount, 1);
    gate.complete(begun());
    await operation;
    expect(order, ['cancelRequest', 'fd-closed', 'release']);
    expect(provider.transactionCount, 0);
    expect(replies.calls.where((r) => r['cache'] != null).single['error'], 'cancelled');
  });
  test('partial pair or invalid begin metadata closes every returned FD then releases by exact owner/attempt', () async {
    for (final value in [
      {'payload': '{"version":1}', 'cacheFd': 40},
      {...begun(), 'stagingFd': -1},
    ]) {
      final replies = Replies();
      final controls = <Map<String, dynamic>>[];
      final provider = DirectoryWriteProvider(
        reply: replies.call,
        isCurrent: () => true,
        android: true,
        invoke: (raw) async {
          final request = jsonDecode(raw) as Map<String, dynamic>;
          if (request['op'] == 'begin') return value;
          controls.add(request);
          return {'payload': '{"version":1}'};
        },
      );
      await handle(provider, request(1));
      expect(replies.calls.single['cache'], 40);
      expect(replies.calls.single['error'], 'invalid');
      expect(controls.single['op'], 'release');
      expect(controls.single['owner'], id(200));
      expect(controls.single['attemptId'], id(100));
      expect(provider.transactionCount, 0);
    }
  });
  test('publication is not timed out or guessed canceled after listener stop; actual success drains old owner', () async {
    final replies = Replies(), publication = Completer<Object?>();
    final calls = <String>[];
    var current = true;
    final provider = DirectoryWriteProvider(
      reply: replies.call,
      isCurrent: () => current,
      android: true,
      beginTimeout: const Duration(milliseconds: 5),
      invoke: (raw) async {
        final value = jsonDecode(raw);
        calls.add(value['op']);
        switch (value['op']) {
          case 'begin':
            return begun();
          case 'publish':
            return publication.future;
          default:
            return {'payload': '{"version":1}'};
        }
      },
    );
    await handle(provider, request(1));
    final saving = handle(provider, request(2, operation: 'publish'));
    current = false;
    await provider.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.pendingCount, 1);
    expect(replies.calls.length, 1);
    expect(calls, ['begin', 'publish', 'cancel']);
    publication.complete({'payload': '{"version":1,"published":true}'});
    await saving;
    expect(jsonDecode(replies.calls.last['payload'] as String)['published'], true);
    expect(replies.calls.last['error'], isNull);
    await handle(provider, request(3, operation: 'release'));
    expect(provider.transactionCount, 0);
    await handle(provider, request(4, attempt: 101));
    expect(replies.calls.last['error'], 'cancelled');
  });
  test('ambiguous publication is unconfirmed, not success or cancellation', () async {
    for (final failure in [PlatformException(code: 'cancelled'), PlatformException(code: 'publication_unconfirmed'), StateError('bridge lost')]) {
      final replies = Replies();
      final provider = DirectoryWriteProvider(
        reply: replies.call,
        isCurrent: () => true,
        android: true,
        invoke: (raw) async {
          final value = jsonDecode(raw);
          if (value['op'] == 'begin') return begun();
          if (value['op'] == 'publish') throw failure;
          return {'payload': '{"version":1}'};
        },
      );
      await handle(provider, request(1));
      await handle(provider, request(2, operation: 'publish'));
      expect(replies.calls.last['error'], 'publication_unconfirmed');
      expect(replies.calls.last['payload'], isNull);
      await handle(provider, request(3, operation: 'release'));
    }
  });
  test('old owner or transaction cannot publish or release a different workspace attempt', () async {
    final replies = Replies();
    var calls = 0;
    final provider = DirectoryWriteProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (raw) async {
        calls++;
        return begun();
      },
    );
    await handle(provider, request(1));
    await handle(provider, request(2, operation: 'publish', owner: 201));
    await handle(provider, {...request(3, operation: 'release'), 'lease': 'wrong'});
    expect(calls, 1);
    expect(replies.calls.skip(1).map((r) => r['error']), ['invalid', 'invalid']);
    expect(provider.transactionCount, 1);
  });
  test('eight real blocked invokes remain occupied across provider replacements and cancellation', () async {
    final gates = <Completer<Object?>>[], pending = <Future<void>>[];
    for (var n = 0; n < 8; n++) {
      final gate = Completer<Object?>();
      gates.add(gate);
      final provider = DirectoryWriteProvider(
        reply: Replies().call,
        isCurrent: () => true,
        android: true,
        invoke: (raw) async {
          if (jsonDecode(raw)['op'] == 'begin') return await gate.future;
          return {'payload': '{"version":1}'};
        },
      );
      pending.add(handle(provider, request(n + 1, attempt: 100 + n)));
      await provider.close();
    }
    final rejected = Replies();
    final next = DirectoryWriteProvider(
      reply: rejected.call,
      isCurrent: () => true,
      android: true,
      invoke: (_) async => throw StateError('Must not invoke a ninth worker'),
    );
    await handle(next, request(50));
    expect(rejected.calls.single['error'], 'busy');
    for (var i = 0; i < 8; i++) {
      gates[i].complete(begun(attempt: 100 + i));
    }
    await Future.wait(pending);
  });
  test('empty directory begin carries no descriptors and same identity publishes then releases', () async {
    final replies = Replies();
    final provider = DirectoryWriteProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (raw) async {
        final value = jsonDecode(raw);
        return value['op'] == 'begin'
            ? begun(directory: true)
            : {
                'payload': jsonEncode({'version': 1, if (value['op'] == 'publish') 'published': true}),
              };
      },
    );
    await handle(provider, request(1, directory: true));
    expect(replies.calls.single['cache'], isNull);
    expect(replies.calls.single['staging'], isNull);
    await handle(provider, request(2, operation: 'publish', directory: true));
    await handle(provider, request(3, operation: 'release', directory: true));
    expect(provider.transactionCount, 0);
  });
  test('unsupported platform and malformed scope fail before native work', () async {
    for (final android in [false, true]) {
      final replies = Replies();
      final provider = DirectoryWriteProvider(
        reply: replies.call,
        isCurrent: () => true,
        android: android,
        invoke: (_) async => throw StateError('must not invoke'),
      );
      await provider.handle(id(1), android ? '{}' : jsonEncode(request(1)));
      expect(replies.calls.single['error'], android ? 'invalid' : 'unsupported');
    }
  });
  test('bridge acknowledgement loss does not prove FD closure or authorize early native release', () async {
    final controls = <String>[];
    final provider = DirectoryWriteProvider(
      reply: ({required requestId, payload, cacheDescriptor, stagingDescriptor, error}) async {
        throw StateError('Bridge acknowledgement lost');
      },
      isCurrent: () => true,
      android: true,
      invoke: (raw) async {
        final value = jsonDecode(raw);
        if (value['op'] == 'begin') return begun();
        controls.add(value['op']);
        return {'payload': '{"version":1}'};
      },
    );
    await handle(provider, request(1));
    expect(controls, ['cancel']);
    expect(provider.transactionCount, 1);
    // Only core's eventual release event asserts that its real FDs are closed.
    await handle(provider, request(2, operation: 'release'));
    expect(controls, ['cancel', 'release']);
    expect(provider.transactionCount, 0);
  });
}
