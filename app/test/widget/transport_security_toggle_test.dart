import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/transport_security_toggle.dart';

void main() {
  test('every locale describes HTTPS and TLS explicitly, including fallback', () async {
    for (final locale in AppLocale.values) {
      final strings = (await locale.build()).transportSecurity;
      expect(strings.title, contains('HTTPS'), reason: locale.languageTag);
      expect(strings.title, contains('TLS'));
      expect(strings.httpDescription, contains('HTTP'));
      expect(strings.certificate, contains('LegnaSend'));
    }
  });

  testWidgets(
    'mobile transport toggle explains file scope and retains its actual boolean',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
      addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
      var value = true;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return TransportSecurityToggle(value: value, showCertificate: true, onChanged: (next) => setState(() => value = next));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('HTTPS 传输（TLS）'), findsOneWidget);
      expect(find.textContaining('不对保存的文件加密'), findsOneWidget);
      expect(find.textContaining('自签名 TLS 证书'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(value, isFalse);
      expect(find.textContaining('自签名 TLS 证书'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
}
