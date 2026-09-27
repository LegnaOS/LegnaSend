import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/changelog_page.dart';

void main() {
  for (final (locale, size, scale, brightness, name) in [
    (AppLocale.en, const Size(1040, 760), 1.0, Brightness.light, 'desktop-en'),
    (AppLocale.zhCn, const Size(390, 844), 1.0, Brightness.light, 'mobile-zh'),
    (AppLocale.zhTw, const Size(390, 844), 1.0, Brightness.dark, 'mobile-hant-dark'),
    (AppLocale.en, const Size(320, 740), 2.0, Brightness.light, 'large-text'),
  ]) {
    testWidgets('release notes fit $name without overflow', (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = Platform.environment['CAPTURE_RELEASE_NOTES'] == '1';
      await tester.runAsync(() async {
        await LocaleSettings.setLocale(locale);
        rootBundle.evict(changelogAssetForLocale(locale));
        await rootBundle.loadString(changelogAssetForLocale(locale));
        if (capture) {
          final fontPath = Platform.environment['RELEASE_NOTES_FONT']!;
          final font = ByteData.sublistView(await File(fontPath).readAsBytes());
          await (FontLoader('ReleaseNotesCapture')..addFont(Future.value(font))).load();
          await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        }
        await Future<void>.delayed(Duration.zero);
      });
      final paint = GlobalKey();
      final theme = getTheme(ColorMode.localsend, Brand.green, brightness, null);
      await tester.pumpWidget(
        RepaintBoundary(
          key: paint,
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: capture ? theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'ReleaseNotesCapture')) : theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const ChangelogPage(),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(Markdown), findsOneWidget);
      final picker = tester.getRect(find.byKey(const ValueKey('changelog-language')));
      expect(picker.left, greaterThanOrEqualTo(0));
      expect(picker.right, lessThanOrEqualTo(size.width));
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final image = await (paint.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/legnasend-release-$name.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  // Let bundle futures finish in their real-I/O zone before advancing animations.
  await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}
