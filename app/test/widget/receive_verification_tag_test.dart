import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/widget/receive_verification_tag.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
      testWidgets('verification tag wraps at 320px for ${platform.name}/${locale.languageTag}', (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: Scaffold(
                body: Column(
                  children: [
                    const ReceiveVerificationTag(verification: FileVerification(attemptId: 'receive', verifiedBytes: 50, totalBytes: 100)),
                    const ReceiveVerificationTag(
                      verification: FileVerification(attemptId: 'send', verifiedBytes: 25, totalBytes: 100, receiving: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('${t.receivePage.verifyingReceivedData} · 50%'), findsOneWidget);
        expect(find.text('${t.sendPage.verifyingSourceData} · 25%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
