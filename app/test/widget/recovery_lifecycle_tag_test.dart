import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/recovery_lifecycle_tag.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
      testWidgets('typed recovery wraps at 320px/1.6x ${platform.name}/${locale.languageTag}', (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        tester.view.physicalSize = const Size(320, 900);
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
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      const RecoveryLifecycleTag(recovery: UploadRecoveryState.waiting(attempt: 1, retryAfterMs: 1000)),
                      for (final kind in UploadRecoveryFailureKind.values)
                        RecoveryLifecycleTag(
                          recovery: UploadRecoveryState.failed(UploadRecoveryFailure(kind: kind, retention: UploadRecoveryRetention.unknown)),
                        ),
                      const RecoveryLifecycleTag(
                        recovery: UploadRecoveryState.failed(
                          UploadRecoveryFailure(
                            kind: UploadRecoveryFailureKind.retryable,
                            retention: UploadRecoveryRetention.confirmed,
                          ),
                        ),
                      ),
                      const RecoveryLifecycleTag(
                        recovery: UploadRecoveryState.failed(
                          UploadRecoveryFailure(
                            kind: UploadRecoveryFailureKind.sourceChanged,
                            retention: UploadRecoveryRetention.notRetained,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text(t.transferActivity.recoveryWaiting), findsOneWidget);
        expect(find.text(t.transferActivity.recoveryAuthorization), findsOneWidget);
        expect(find.text(t.transferActivity.recoveryRetentionUnknown), findsNWidgets(4));
        expect(find.text(t.transferActivity.recoveryRetained), findsOneWidget);
        expect(find.text(t.transferActivity.recoveryNotRetained), findsOneWidget);
        expect(find.textContaining('100%'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
