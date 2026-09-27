import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/ios_share_inbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legnasend/ios_share');
  const id = '12345678-1234-1234-1234-123456789ABC';
  final payload = {
    'batchId': id,
    'content': 'shared text',
    'attachments': [
      {'path': '/private/inbox/$id/item-0/中文 100%.txt', 'type': 3},
    ],
  };
  late bool pending;
  late int acknowledgements;
  setUp(() {
    pending = true;
    acknowledgements = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'next') return pending ? payload : null;
      expect(call.method, 'acknowledge');
      expect(call.arguments, {'batchId': id});
      pending = false;
      acknowledgements++;
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('startup/resume share one drain and only ack successful enqueue', () async {
    final inbox = IosShareInbox();
    final gate = Completer<void>();
    var deliveries = 0;
    final first = inbox.drain((batchId, media) async {
      deliveries++;
      expect(media.attachments!.single!.path, '/private/inbox/$id/item-0/中文 100%.txt');
      expect(media.content, 'shared text');
      await gate.future;
    });
    final second = inbox.drain((_, _) async => fail('duplicate delivery'));
    await Future<void>.delayed(Duration.zero);
    expect(deliveries, 1);
    expect(acknowledgements, 0);
    gate.complete();
    expect(await first, true);
    expect(await second, true);
    expect(acknowledgements, 1);
  });

  test('failed enqueue retains manifest and succeeds on retry', () async {
    final inbox = IosShareInbox();
    await expectLater(inbox.drain((_, _) async => throw StateError('staging failed')), throwsStateError);
    expect(pending, true);
    expect(acknowledgements, 0);
    expect(await inbox.drain((_, _) async {}), true);
    expect(acknowledgements, 1);
  });

  test('failed acknowledgement retries without duplicating staged media', () async {
    final inbox = IosShareInbox();
    var failAck = true;
    var deliveries = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'next') return pending ? payload : null;
      if (failAck) throw PlatformException(code: 'writeFailed');
      pending = false;
      return null;
    });
    await expectLater(
      inbox.drain((_, _) async {
        deliveries++;
      }),
      throwsA(isA<PlatformException>()),
    );
    failAck = false;
    await inbox.drain((_, _) async {
      deliveries++;
    });
    expect(deliveries, 1);
  });
}
