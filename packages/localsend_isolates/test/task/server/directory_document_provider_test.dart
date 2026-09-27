import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/directory_document_provider.dart';

String request(String id, {String operation = 'open', int generation = 1}) => jsonEncode({
  'version': 1,
  'owner': '11111111-1111-4111-8111-111111111111',
  'requestId': id,
  'workspaceId': 'workspace',
  'generation': generation,
  'tree': 'content://documents/tree/root',
  'op': operation,
  'documentId': 'opaque-document',
});

class Replies {
  final calls = <Map<String, Object?>>[];
  Future<bool> call({required String requestId, String? payload, int? fileDescriptor, String? error}) async {
    calls.add({'id': requestId, 'payload': payload, 'fd': fileDescriptor, 'error': error});
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual channel uses request envelope and transfers descriptor once', () async {
    const channel = MethodChannel('org.localsend.localsend_app/localsend');
    final replies = Replies();
    final messages = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'workspaceDocuments');
      messages.add(call.arguments);
      return {'payload': '{"version":1}', 'fd': 42};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final provider = DirectoryDocumentProvider(reply: replies.call, isCurrent: () => true, android: true);
    await provider.handle('one', request('one'));
    expect(messages, [
      {'request': request('one')},
    ]);
    expect(replies.calls.single['fd'], 42);
    expect(replies.calls.single['error'], isNull);
    expect(provider.pendingCount, 0);
  });
  test('state observation preserves scope identity and forwards payload without a descriptor', () async {
    final replies = Replies();
    final calls = <Map<String, dynamic>>[];
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (value) async {
        calls.add(jsonDecode(value) as Map<String, dynamic>);
        return {'payload': '{"version":1,"changed":true}'};
      },
    );
    await provider.handle('state-request', request('state-request', operation: 'state', generation: 7));
    expect(calls.single['op'], 'state');
    expect(calls.single['owner'], '11111111-1111-4111-8111-111111111111');
    expect(calls.single['generation'], 7);
    expect(replies.calls.single['payload'], '{"version":1,"changed":true}');
    expect(replies.calls.single['fd'], isNull);
    expect(replies.calls.single['error'], isNull);
    await provider.close();
    expect(calls.last['op'], 'close');
    expect(calls.last['generation'], 7);
  });
  test('Android-only and malformed requests never reach the native provider', () async {
    var invocations = 0;
    final replies = Replies();
    for (final android in [false, true]) {
      final provider = DirectoryDocumentProvider(
        reply: replies.call,
        isCurrent: () => true,
        android: android,
        invoke: (_) async {
          invocations++;
          return null;
        },
      );
      await provider.handle('id', android ? '{}' : request('id'));
    }
    expect(invocations, 0);
    expect(replies.calls.map((r) => r['error']), ['unsupported', 'invalid']);
  });
  test('invalid native metadata still transfers its detached descriptor for cleanup', () async {
    final replies = Replies();
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (_) async => {'payload': false, 'fd': 51},
    );
    await provider.handle('id', request('id'));
    expect(replies.calls.single['fd'], 51);
    expect(replies.calls.single['error'], 'invalid');
  });
  test('listener replacement sends late descriptor only to the captured original responder', () async {
    final old = Replies(), next = Replies();
    var current = true;
    final result = Completer<Object?>();
    final provider = DirectoryDocumentProvider(reply: old.call, isCurrent: () => current, android: true, invoke: (_) => result.future);
    final pending = provider.handle('old', request('old'));
    current = false;
    DirectoryDocumentProvider(reply: next.call, isCurrent: () => true, android: true);
    result.complete({'payload': '{}', 'fd': 61});
    await pending;
    expect(old.calls.single['fd'], 61);
    expect(old.calls.single['error'], 'cancelled');
    expect(next.calls, isEmpty);
  });
  test('timeout cancels native request but holds its slot; late FD is reclaimed by old Rust responder', () async {
    final replies = Replies(), result = Completer<Object?>();
    final controls = <Map<String, dynamic>>[];
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      timeout: const Duration(milliseconds: 10),
      invoke: (value) {
        final parsed = jsonDecode(value) as Map<String, dynamic>;
        if (parsed['op'] == 'cancel') {
          controls.add(parsed);
          return Future.value({'payload': '{}'});
        }
        return result.future;
      },
    );
    final pending = provider.handle('timed', request('timed'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(provider.pendingCount, 1);
    expect(replies.calls.single['error'], 'expired');
    expect(controls.single, {'version': 1, 'op': 'cancel', 'requestId': 'timed'});
    result.complete({'payload': '{}', 'fd': 71});
    await pending;
    expect(replies.calls.where((r) => r['fd'] != null).single['fd'], 71);
    expect(provider.pendingCount, 0);
  });
  test('closing a listener cancels pending work and closes only its own scope generation', () async {
    final replies = Replies(), result = Completer<Object?>();
    final controls = <Map<String, dynamic>>[];
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (value) {
        final parsed = jsonDecode(value) as Map<String, dynamic>;
        if (parsed['op'] == 'open') return result.future;
        controls.add(parsed);
        return Future.value({'payload': '{}'});
      },
    );
    final pending = provider.handle('old', request('old', generation: 5));
    await provider.close();
    await provider.close();
    expect(controls.where((r) => r['op'] == 'close').single['generation'], 5);
    expect(controls.where((r) => r['op'] == 'close').single['owner'], '11111111-1111-4111-8111-111111111111');
    expect(controls.where((r) => r['op'] == 'cancel').single['requestId'], 'old');
    result.complete({'payload': '{}', 'fd': 81});
    await pending;
    expect(replies.calls.where((r) => r['fd'] != null).single['fd'], 81);
  });
  test('platform failures expose only stable error codes, never private provider messages', () async {
    final replies = Replies();
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (_) async => throw PlatformException(code: 'unknown-provider-code', message: 'private path and token'),
    );
    await provider.handle('id', request('id'));
    expect(replies.calls.single['error'], 'provider_error');
    expect(replies.calls.toString(), isNot(contains('private')));
  });
  test('sixteen blocked requests remain bounded even after native cancellation', () async {
    final replies = Replies(), result = Completer<Object?>();
    final provider = DirectoryDocumentProvider(
      reply: replies.call,
      isCurrent: () => true,
      android: true,
      invoke: (value) => jsonDecode(value)['op'] == 'cancel' ? Future.value({'payload': '{}'}) : result.future,
    );
    final pending = [for (var i = 0; i < 16; i++) provider.handle('$i', request('$i'))];
    await provider.cancel('0');
    await provider.handle('overflow', request('overflow'));
    expect(provider.pendingCount, 16);
    expect(replies.calls.last['error'], 'busy');
    result.complete({'payload': '{}'});
    await Future.wait(pending);
    expect(provider.pendingCount, 0);
  });
}
