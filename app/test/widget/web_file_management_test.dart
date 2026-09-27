import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/web_shared_files_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../fixtures/web_file_management_fixture.dart';
import '../mocks.mocks.dart';

void main() {
  final captureKey = GlobalKey();
  const capture = bool.fromEnvironment('CAPTURE_MANAGEMENT_UI');
  Future<ManagedFileServer> open(
    WidgetTester tester, {
    int count = 3,
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await LocaleSettings.setLocale(AppLocale.en);
    if (capture) {
      await tester.runAsync(() async {
        await (FontLoader('ManagementTest')..addFont(rootBundle.load('packages/yaru/assets/fonts/Ubuntu-R.ttf'))).load();
        await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    final server = ManagedFileServer(count: count);
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          serverProvider.overrideWithNotifier((_) => server),
          settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
          webFilePublisherProvider.overrideWithValue((_, _) async {}),
          webReplacementPickerProvider.overrideWithValue((_) async => [queuedFile('new-selection', 20).copyWith(path: '/source/new.bin')]),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: getTheme(ColorMode.localsend, Colors.green, brightness, null).copyWith(
              textTheme: capture ? getTheme(ColorMode.localsend, Colors.green, brightness, null).textTheme.apply(fontFamily: 'ManagementTest') : null,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(key: captureKey, child: const WebSharedFilesPage(generation: 7)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets('withdraw confirmation is scoped, cancellable and keeps the sharing service', (tester) async {
    final server = await open(tester);
    await tester.tap(find.byKey(const ValueKey('withdraw-file-0')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(server.state!.webDownloadState!.files.length, 3);
    await tester.tap(find.byKey(const ValueKey('withdraw-file-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-file-change')));
    await tester.pumpAndSettle();
    expect(server.state!.webDownloadState!.files.containsKey('file-0'), false);
    expect(server.state!.session!.sessionId, 'parallel');
    expect(server.generation, 7);
    expect(find.byType(WebSharedFilesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement keeps the manager open and creates a fresh ID; stale confirmation is ignored', (tester) async {
    final server = await open(tester);
    await tester.tap(find.byKey(const ValueKey('replace-file-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('new-selection.bin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-file-change')));
    await tester.pumpAndSettle();
    expect(server.state!.webDownloadState!.files.length, 3);
    expect(server.state!.webDownloadState!.files.containsKey('file-0'), false);
    expect(find.text('new-selection.bin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('withdraw-file-1')));
    await tester.pumpAndSettle();
    server.changeShare();
    await tester.tap(find.byKey(const ValueKey('confirm-file-change')));
    await tester.pumpAndSettle();
    expect(server.state!.webDownloadState!.files.length, 3);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('withdraw-file-1'))).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 740), const Size(1040, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets('5000 files stay bounded and searchable, $size, $brightness', (tester) async {
        await open(tester, count: 5000, size: size, scale: 2, brightness: brightness);
        if (capture) {
          await tester.runAsync(() async {
            final image = await (captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('/tmp/legnasend-management-${size.width.toInt()}-${brightness.name}.png').writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(find.byType(Card).evaluate().length, lessThan(20));
        expect(find.text('1 / 100'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('shared-files-next')));
        await tester.pumpAndSettle();
        expect(find.text('2 / 100'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('shared-file-search')), 'file-4999');
        await tester.pumpAndSettle();
        expect(find.text('file-4999.bin'), findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        expect(find.byKey(const ValueKey('shared-file-file-4999')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
    }
  }
}
