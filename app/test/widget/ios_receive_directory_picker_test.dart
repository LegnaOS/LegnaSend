import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/receive_options_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';

class _ReceiveServer extends ServerService {
  final changes = <String>[];
  @override
  ServerState? init() => ServerState(
    alias: 'Receiver',
    port: 53317,
    https: false,
    session: incoming('approved', status: SessionStatus.waiting),
    web: null,
  );
  @override
  void setSessionDestinationDir(String directory, {String? expectedSessionId}) {
    expect(expectedSessionId, 'approved');
    changes.add(directory);
    state = state!.copyWith(session: state!.session!.copyWith(destinationDirectory: directory));
  }
}

void main() {
  const channel = MethodChannel('legnasend/ios_receive');
  setUp(() async => LocaleSettings.setLocale(AppLocale.en));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  for (final outcome in ['selected', 'cancelled', 'rejected']) {
    testWidgets('iOS receive picker $outcome uses native Files channel and keeps cancellation quiet', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (outcome == 'rejected') throw PlatformException(code: 'ACCESS_REVOKED', message: 'private bookmark data');
        return outcome == 'selected' ? '/private/var/mobile/Library/Mobile Documents/Inbox' : null;
      });
      var destination = '/current';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final selected = await pickReceiveDirectoryPath(context);
                  if (selected != null) destination = selected;
                },
                child: const Text('Choose destination'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose destination'));
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), ['pick']);
      expect(destination, outcome == 'selected' ? '/private/var/mobile/Library/Mobile Documents/Inbox' : '/current');
      expect(find.byType(AlertDialog), outcome == 'rejected' ? findsOneWidget : findsNothing);
      if (outcome == 'rejected') {
        expect(find.text(t.receivePage.destinationUnavailable), findsOneWidget);
        expect(find.textContaining('private bookmark'), findsNothing);
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  for (final outcome in ['selected', 'cancelled', 'rejected']) {
    testWidgets('iOS receive options exposes destination and $outcome changes only the approved session', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pick');
        if (outcome == 'rejected') throw PlatformException(code: 'UNAVAILABLE');
        return outcome == 'selected' ? '/selected/Files' : null;
      });
      final server = _ReceiveServer();
      final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
      final session = container.read(serverProvider)!.session!;
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              home: ReceiveOptionsPage(
                ReceivePageVm(
                  status: SessionStatus.waiting,
                  sessionId: session.sessionId,
                  sender: session.sender,
                  showSenderInfo: false,
                  files: [],
                  message: null,
                  onAccept: () {},
                  onDecline: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('/destination'), findsOneWidget);
      expect(find.byIcon(Icons.edit), findsOneWidget);
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();
      expect(server.changes, outcome == 'selected' ? ['/selected/Files'] : isEmpty);
      expect(container.read(serverProvider)!.session!.destinationDirectory, outcome == 'selected' ? '/selected/Files' : '/destination');
      expect(find.byType(AlertDialog), outcome == 'rejected' ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
      container.disposeContainer();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  for (final invalidPath in ['', 'relative/folder', '/folder\u0000bad']) {
    testWidgets(
      'iOS invalid native directory is rejected without changing selection (${invalidPath.isEmpty
          ? 'empty'
          : invalidPath.startsWith('/')
          ? 'nul'
          : 'relative'})',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => invalidPath);
        var destination = '/current';
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final selected = await pickReceiveDirectoryPath(context);
                  if (selected != null) destination = selected;
                },
                child: const Text('Pick'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Pick'));
        await tester.pumpAndSettle();
        expect(destination, '/current');
        expect(find.text(t.receivePage.destinationUnavailable), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'receive directory capability does not expand general filesystem access on iOS',
    (tester) async {
      expect(checkPlatformWithReceiveDirectory(), isTrue);
      expect(checkPlatformWithFileSystem(), defaultTargetPlatform != TargetPlatform.iOS);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}),
  );

  testWidgets(
    'other platforms retain their injected directory picker and never call iOS channel',
    (tester) async {
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        nativeCalls++;
        return null;
      });
      String? destination;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                destination = await pickReceiveDirectoryPath(context, pick: () async => '/existing/platform-picker');
              },
              child: const Text('Pick'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(destination, '/existing/platform-picker');
      expect(nativeCalls, 0);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}),
  );
}
