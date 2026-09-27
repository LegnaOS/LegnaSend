import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/pages/whats_new_page.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  testWidgets(
    'bundled changelog follows English, simplified, traditional and explicit fallback',
    (tester) async {
      await _prepare(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: ChangelogPage())));
      await _settle(tester);
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend Changelog'));

      for (final locale in [AppLocale.zhCn, AppLocale.zhHk, AppLocale.zhTw]) {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        await _settle(tester);
        final traditional = locale != AppLocale.zhCn;
        final body = tester.widget<Markdown>(find.byType(Markdown)).data;
        expect(body, startsWith(traditional ? '# LegnaSend 更新日誌' : '# LegnaSend 更新日志'));
        expect(body, contains(traditional ? '目錄工作區' : '目录工作区'));
        expect(find.text(traditional ? '跟隨應用程式語言' : '跟随应用语言'), findsOneWidget);
      }

      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.de));
      await _settle(tester);
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend Changelog'));
      expect(find.textContaining('Showing English'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );

  testWidgets('manual language selection does not change app locale and can return to automatic', (tester) async {
    await _prepare(tester);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: ChangelogPage())));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('changelog-language')));
    await _settle(tester);
    await tester.tap(find.text('繁體中文').last);
    await _settle(tester);
    expect(LocaleSettings.currentLocale, AppLocale.en);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend 更新日誌'));
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
    await _settle(tester);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend 更新日誌'));
    await tester.tap(find.byKey(const ValueKey('changelog-language')));
    await _settle(tester);
    await tester.tap(find.text('跟随应用语言').last);
    await _settle(tester);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend 更新日志'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('What is New opens the full changelog and back returns to its summary', (tester) async {
    await _prepare(tester);
    final navigation = NavigationService();
    await tester.pumpWidget(
      RefenaScope(
        overrides: [navigationProvider.overrideWithValue(navigation)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigation.key,
            home: const WhatsNewPage(version: Brand.version),
          ),
        ),
      ),
    );
    await _settle(tester);
    final button = find.widgetWithText(TextButton, 'Changelog');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await _settle(tester);
    expect(find.byType(ChangelogPage), findsOneWidget);
    expect(find.byType(Markdown), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(ChangelogPage), findsNothing);
    expect(find.byType(WhatsNewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed asset load shows retry and a real second attempt recovers', (tester) async {
    await _prepare(tester);
    final bundle = _FailOnceBundle();
    await tester.pumpWidget(
      TranslationProvider(
        child: DefaultAssetBundle(
          bundle: bundle,
          child: const MaterialApp(home: ChangelogPage()),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('The release notes could not be loaded.'), findsOneWidget);
    expect(find.byType(Markdown), findsNothing);
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(bundle.calls, 2);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, '# Recovered');
    expect(tester.takeException(), isNull);
  });

  testWidgets('late asset result cannot replace the newly selected language', (tester) async {
    await _prepare(tester);
    final bundle = _DelayedBundle();
    await tester.pumpWidget(
      TranslationProvider(
        child: DefaultAssetBundle(
          bundle: bundle,
          child: const MaterialApp(home: ChangelogPage()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<int>>(find.byKey(const ValueKey('changelog-language')));
    dropdown.onChanged!(ChangelogLanguage.simplifiedChinese.index);
    await tester.pump();
    bundle.completions[ChangelogLanguage.simplifiedChinese.asset]!.complete('# 新记录');
    await _settle(tester);
    bundle.completions[ChangelogLanguage.english.asset]!.complete('# Stale');
    await _settle(tester);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, '# 新记录');
    expect(bundle.completions.length, 2);
  });

  testWidgets(
    'What is New reads translations at build time rather than capturing its opening language',
    (tester) async {
      await _prepare(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final page = WhatsNewPage.fromLastVersion(lastVersion: null)!;
      await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: page)));
      await _settle(tester);
      expect(find.text("What's new in ${Brand.version}"), findsOneWidget);
      expect(find.text('- 1.0.0 is a development version and has not been officially released.'), findsOneWidget);
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
      await _settle(tester);
      expect(find.text('${Brand.version} 中的新增功能'), findsOneWidget);
      expect(find.text('- 1.0.0 当前为开发版本，尚未正式发布。'), findsOneWidget);
      expect(find.text('- 1.0.0 is a development version and has not been officially released.'), findsNothing);
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
      await _settle(tester);
      expect(find.text('- 1.0.0 目前為開發版本，尚未正式發佈。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
}

class _FailOnceBundle extends CachingAssetBundle {
  int calls = 0;
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    calls++;
    if (calls == 1) throw StateError('fixture asset failure');
    return '# Recovered';
  }
}

class _DelayedBundle extends CachingAssetBundle {
  final completions = <String, Completer<String>>{};
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
  @override
  Future<String> loadString(String key, {bool cache = true}) => (completions[key] ??= Completer<String>()).future;
}

Future<void> _prepare(WidgetTester tester) async {
  // Asset I/O and deferred translations live outside the widget fake clock.
  // Do not carry futures or async locale callbacks across test variants.
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async {
    await LocaleSettings.setLocale(AppLocale.en);
    for (final language in ChangelogLanguage.values) {
      rootBundle.evict(language.asset);
      await rootBundle.loadString(language.asset);
    }
    await Future<void>.delayed(Duration.zero);
  });
}

Future<void> _settle(WidgetTester tester) async {
  // Phase 1: interleave real-async flushes with pumps so platform-channel
  // asset loads (rootBundle.loadString cache:false) land and FutureBuilder rebuilds.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  // Phase 2: continuous frame pumps for route transition animations (~300ms).
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
