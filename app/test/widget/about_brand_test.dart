import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/about/about_page.dart';
import 'package:localsend_app/pages/donation/donation_page.dart';

void main() {
  testWidgets('About shows the fork author and version on mobile layouts', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await LocaleSettings.setLocale(AppLocale.en);
    addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: AboutPage())));
    await tester.pumpAndSettle();
    expect(find.text('About LegnaSend'), findsOneWidget);
    expect(find.text(Brand.author), findsOneWidget);
    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(find.text('Derived from LocalSend · 派生于 LocalSend'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  testWidgets(
    'official website and source links open distinct destinations and locale changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await LocaleSettings.setLocale(AppLocale.en);
      addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
      final launched = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: AboutPage())));
      await tester.pumpAndSettle();
      await tester.tap(find.text(Brand.homepage));
      await tester.pumpAndSettle();
      await tester.tap(find.text(Brand.repository));
      await tester.pumpAndSettle();
      expect(launched, [Brand.homepage, Brand.repositoryUrl]);
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
      await tester.pumpAndSettle();
      expect(find.text('版本 1.0.0'), findsOneWidget);
      expect(find.text('Version 1.0.0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}),
  );

  testWidgets('retained legacy donation route shows About with no checkout or donation buttons', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: DonationPage())));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('Donate'), findsNothing);
    expect(find.text('Ko-fi'), findsNothing);
    expect(find.text('Restore purchase'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
