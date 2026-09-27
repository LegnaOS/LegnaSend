import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_documentation_page.dart';

void main() {
  test('offline API assets include four contracts and detailed bilingual guides', () {
    for (final lang in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
      expect(
        File('assets/api_docs/integration-openapi-$lang.json').readAsStringSync(),
        File('../docs/api/integration-openapi-$lang.json').readAsStringSync(),
      );
    }
    for (final suffix in ['', '_ZH']) {
      final durable = File('assets/api_docs/NATIVE_DURABLE_RESUME$suffix.md').readAsStringSync();
      for (final term in ['resumeKey', 'verifiedBytes', 'POST suspend', 'NATIVE_RESUME_PROTOCOL$suffix.md']) {
        expect(durable, contains(term));
      }
      final guide = File('assets/api_docs/API_RECEIVE_RETENTION$suffix.md').readAsStringSync();
      for (final term in ['receiveCacheRetentionDays', 'effectiveDays', 'automaticCleanupPaused', 'settings_busy', 'cURL', 'JavaScript', 'Python']) {
        expect(guide, contains(term));
      }
      final text = File('assets/api_docs/INTEGRATION_API$suffix.md').readAsStringSync();
      expect(text, isNot(contains('](evidence/')));
      expect(text, isNot(contains('](api/')));
      for (final term in ['cURL', 'JavaScript', 'Python', 'Retry-After', 'If-Match', 'generation', 'http://HOST:PORT']) {
        expect(text, contains(term));
      }
    }
  });
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('offline API navigation ${locale.languageTag}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: ApiDocumentationPage())));
      Future<void> settle() async {
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpAndSettle();
      }

      await settle();
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, contains('## '));
      await tester.tap(find.text(t.integrationApi.directoryContract));
      await settle();
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, contains('/api/legnasend/v1/workspaces'));
      await tester.tap(find.text(locale.languageCode == 'zh' ? '接收保留策略' : 'Receive retention'));
      await settle();
      final retention = tester.widget<Markdown>(find.byType(Markdown));
      expect(retention.data, contains('receiveCacheRetentionDays'));
      expect(retention.data, contains('automaticCleanupPaused'));
      expect(retention.data, contains('settings_busy'));
      for (final language in ['cURL', 'JavaScript', 'Python']) {
        expect(retention.data, contains(language));
      }
      await tester.tap(find.text(locale.languageCode == 'zh' ? '原生续传协议' : 'Native recovery'));
      await settle();
      final recovery = tester.widget<Markdown>(find.byType(Markdown));
      expect(recovery.data, contains('resumeKey'));
      expect(recovery.data, contains('verifiedBytes'));
      recovery.onTapLink!('baseline', locale.languageCode == 'zh' ? 'NATIVE_RESUME_PROTOCOL_ZH.md' : 'NATIVE_RESUME_PROTOCOL.md', '');
      await settle();
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, contains('1048576'));
      await tester.tap(find.text('OpenAPI 3.1'));
      await settle();
      expect(find.byType(Markdown), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
      await tester.tap(find.text('English').first);
      await settle();
      expect(tester.widget<Markdown>(find.byType(Markdown)).data, startsWith('# LegnaSend'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  }
}
