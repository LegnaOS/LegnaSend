import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android;
import 'package:localsend_app/util/native/pick_directory_path.dart';

void main() {
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  testWidgets('receive directory asks for write access but read-only picking remains available', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'content://provider/tree/id';
    });
    await android.pickDirectoryPathAndroid(requireWrite: true);
    await android.pickDirectoryPathAndroid();
    expect(calls.map((c) => c.arguments), [
      {'requireWrite': true},
      {'requireWrite': false},
    ]);
  });
  testWidgets('late directory result does not update a closed receive page', (tester) async {
    final picked = Completer<String?>();
    String? selected = 'old';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await pickReceiveDirectoryPath(context, pick: () => picked.future);
              if (result != null) selected = result;
            },
            child: const Text('pick'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpWidget(const SizedBox());
    picked.complete('content://provider/tree/new');
    await tester.pumpAndSettle();
    expect(selected, 'old');
  });
  for (final failed in [false, true]) {
    testWidgets('picker ${failed ? 'failure uses a page modal' : 'cancellation is quiet'} and keeps old destination', (tester) async {
      String? selected = 'old';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final value = await pickReceiveDirectoryPath(
                    context,
                    pick: () async {
                      if (failed) throw PlatformException(code: 'PERMISSION_DENIED', message: 'private provider diagnostic');
                      return null;
                    },
                  );
                  if (value != null) selected = value;
                },
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      expect(selected, 'old');
      expect(find.byType(AlertDialog), failed ? findsOneWidget : findsNothing);
      if (failed) {
        expect(find.text(t.receivePage.destinationUnavailable), findsOneWidget);
        expect(find.textContaining('private provider diagnostic'), findsNothing);
        // Dismiss through the modal barrier rather than requiring routerino setup.
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
      }
    });
  }
}
