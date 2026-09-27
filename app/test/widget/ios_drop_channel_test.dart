import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/ios_drop_channel.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:refena_flutter/refena_flutter.dart';

Future<Object?> nativeCall(WidgetTester tester, String channel, String method, Object? arguments) async {
  const codec = StandardMethodCodec();
  final reply = Completer<ByteData?>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(channel, codec.encodeMethodCall(MethodCall(method, arguments)), reply.complete);
  final bytes = await reply.future;
  return bytes == null ? null : codec.decodeEnvelope(bytes);
}

void main() {
  testWidgets('iOS prepare freezes a destination before import and rejects malformed coordinates', (tester) async {
    var visibleTarget = 'receiver-A';
    String? frozenTarget;
    var failures = 0;
    final controller = IosDropController(
      prepare: (position) {
        expect(position, const Offset(24, 36));
        frozenTarget = visibleTarget;
        return true;
      },
      failed: () => failures++,
    )..attach();
    addTearDown(controller.dispose);
    expect(await nativeCall(tester, 'legnasend/ios_drop', 'prepare', [24.0, 36.0]), true);
    visibleTarget = 'receiver-B';
    expect(frozenTarget, 'receiver-A');
    for (final args in [
      null,
      [1],
      ['24', 36],
      [double.infinity, 36],
    ]) {
      expect(await nativeCall(tester, 'legnasend/ios_drop', 'prepare', args), false);
    }
    await nativeCall(tester, 'legnasend/ios_drop', 'failed', 'importFailed');
    expect(failures, 1);
  });

  testWidgets('a modal or hidden route can reject import before native source copying', (tester) async {
    final controller = IosDropController(prepare: (_) => false, failed: () {})..attach();
    addTearDown(controller.dispose);
    expect(await nativeCall(tester, 'legnasend/ios_drop', 'prepare', [1.0, 2.0]), false);
  });

  testWidgets('UIKit logical point events reach exactly one existing DropTarget after delayed export', (tester) async {
    final drops = <DropDoneDetails>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DropTarget(onDragDone: drops.add, child: const SizedBox.expand()),
      ),
    );
    await nativeCall(tester, 'desktop_drop', 'entered', [50.0, 80.0]);
    await nativeCall(tester, 'desktop_drop', 'exited', null);
    // UIKit may finish its drag while a file provider is still materializing.
    await nativeCall(tester, 'desktop_drop', 'updated', [50.0, 80.0]);
    await nativeCall(tester, 'desktop_drop', 'performOperation', ['/support/batch/item-0/目录', '/support/batch/item-1/视频.mov']);
    expect(drops.length, 1);
    expect(drops.single.globalPosition, const Offset(50, 80));
    expect(drops.single.files.map((file) => file.path), ['/support/batch/item-0/目录', '/support/batch/item-1/视频.mov']);
    await nativeCall(tester, 'desktop_drop', 'exited', null);
    expect(drops.length, 1);
  });

  test('native cleanup runs under the same source lease and waits out new Dart acquisitions', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('legnasend/ios_drop');
    final cleanStarted = Completer<void>();
    final allowCleanup = Completer<void>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'clearIfIdle');
      calls++;
      cleanStarted.complete();
      await allowCleanup.future;
      return false; // An active native provider copy may independently block deletion.
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = RefenaContainer(
      overrides: [
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {}),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.disposeContainer);
    final guard = container.read(sourceCacheLeaseProvider);
    final existing = await guard.acquire();
    await container.global.dispatchAsync(ClearCacheAction());
    expect(calls, 0, reason: 'Existing acquisition prevents native cleanup entirely');
    existing.release();
    final cleaning = container.global.dispatchAsync(ClearCacheAction());
    await cleanStarted.future;
    var acquired = false;
    final pending = guard.acquire().then((lease) {
      acquired = true;
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(acquired, false);
    allowCleanup.complete();
    await cleaning;
    (await pending).release();
    expect(calls, 1);
  });

  test('iOS import failure has Simplified Chinese, Traditional Chinese and English fallback', () {
    expect(iosDropFailureText(AppLocale.zhCn), contains('导入'));
    expect(iosDropFailureText(AppLocale.zhTw), contains('匯入'));
    expect(iosDropFailureText(AppLocale.zhHk), iosDropFailureText(AppLocale.zhTw));
    expect(iosDropFailureText(AppLocale.en), contains('import'));
    expect(iosDropFailureText(AppLocale.de), iosDropFailureText(AppLocale.en));
  });
}
