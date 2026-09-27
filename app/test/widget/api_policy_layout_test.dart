import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/tabs/api_tab.dart';
import 'package:localsend_app/provider/integration_api_publication_provider.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';
import '../unit/api/api_fixtures.dart';
import '../unit/workspace/directory_publication_test.dart' show TestWorkspaceCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

class _NonlinearQuotaScaler extends TextScaler {
  const _NonlinearQuotaScaler();
  @override
  double scale(double fontSize) => fontSize <= 20 ? fontSize * 2 : fontSize;
  @override
  double get textScaleFactor => 2;
}

void main() {
  for (final (width, scale, locale, brightness, platform) in [
    (1040.0, 1.0, AppLocale.zhCn, Brightness.light, TargetPlatform.macOS),
    (1040.0, 1.0, AppLocale.en, Brightness.dark, TargetPlatform.windows),
    (1040.0, 1.6, AppLocale.zhHk, Brightness.dark, TargetPlatform.linux),
    (600.0, 1.0, AppLocale.en, Brightness.light, TargetPlatform.linux),
    (600.0, 2.0, AppLocale.en, Brightness.dark, TargetPlatform.android),
    (390.0, 1.0, AppLocale.zhCn, Brightness.light, TargetPlatform.android),
    (390.0, 1.0, AppLocale.en, Brightness.dark, TargetPlatform.iOS),
    (320.0, 2.0, AppLocale.en, Brightness.dark, TargetPlatform.android),
    (320.0, 2.0, AppLocale.zhHk, Brightness.light, TargetPlatform.iOS),
  ]) {
    testWidgets('API quota label geometry $width $scale ${locale.languageTag} $brightness', (tester) async {
      final size = Size(width, 900), paint = GlobalKey();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final store = MemoryApiStore(), server = ApiTestServer(), settings = SettingsService(MockPersistenceService());
      final container = RefenaContainer(
        overrides: [
          integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: store)),
          integrationApiValidatorProvider.overrideWithValue((_) async {}),
          serverProvider.overrideWithNotifier((_) => server),
          localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
          workspaceCatalogProvider.overrideWithNotifier((_) => TestWorkspaceCatalog(MemoryWorkspaceStore())),
        ],
      );
      addTearDown(container.disposeContainer);
      final api = container.notifier(integrationApiSettingsProvider);
      await api.initialize();
      await container.notifier(integrationApiPublicationProvider).synchronize();
      final screenshots = Platform.environment['LEGNASEND_API_POLICY_SCREENSHOTS'];
      var theme = getTheme(ColorMode.localsend, const Color(0xff54b865), brightness, null);
      if (screenshots != null) {
        await tester.runAsync(() async {
          await (FontLoader('QuotaTest')..addFont(rootBundle.load('packages/yaru/assets/fonts/Ubuntu-R.ttf'))).load();
          await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
          final fontPath = Platform.environment['LEGNASEND_API_CJK_FONT'];
          if (fontPath != null) {
            final bytes = await File(fontPath).readAsBytes();
            await (FontLoader('QuotaCJK')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'QuotaTest', fontFamilyFallback: ['QuotaCJK']),
        );
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: paint,
          child: RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: [locale.flutterLocale],
                locale: locale.flutterLocale,
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: width == 600 && scale == 2 ? const _NonlinearQuotaScaler() : TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(body: ApiTab()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(t.integrationApi.editPolicy));
      await tester.tap(find.text(t.integrationApi.editPolicy));
      await tester.pumpAndSettle();
      for (var group = 0; group < 3; group++) {
        for (var field = 0; field < 3; field++) {
          final finder = find.byKey(ValueKey('api-limit-$group-$field'));
          final box = tester.getRect(finder);
          expect(box.height, greaterThanOrEqualTo(48), reason: 'Quota input must not collapse under the application input theme');
          final label = tester.getRect(find.byKey(ValueKey('api-limit-$group-$field-label')));
          expect(box.top - label.bottom, closeTo(6, 0.1));
          expect(box.left, greaterThanOrEqualTo(0));
          expect(box.right, lessThanOrEqualTo(width));
          final value = tester.getRect(find.descendant(of: finder, matching: find.byType(EditableText)));
          expect(value.top, greaterThanOrEqualTo(box.top + 11.9));
          expect(value.bottom, lessThanOrEqualTo(box.bottom - 11.9));
          if (field > 0) {
            final previous = tester.getRect(find.byKey(ValueKey('api-limit-$group-${field - 1}')));
            if (width <= 390 || scale > 1) expect(box.left, closeTo(previous.left, 0.1));
            if ((box.left - previous.left).abs() > 1) {
              expect(box.top, closeTo(previous.top, 0.1));
            } else {
              expect(label.top, greaterThanOrEqualTo(previous.bottom + 11.9));
            }
          }
        }
      }
      expect(tester.takeException(), isNull);
      if (screenshots != null) {
        await tester.runAsync(() async {
          final image = await (paint.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshots).create(recursive: true);
          await File(
            '$screenshots/policy-${width.toInt()}-$scale-${locale.languageTag}-${brightness.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final semantics = tester.ensureSemantics();
      final first = find.byKey(const ValueKey('api-limit-0-0'));
      try {
        await tester.ensureVisible(first);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(tester.getSemantics(first).getSemanticsData().label, contains('${t.integrationApi.global} · ${t.integrationApi.second}'));
        expect(tester.getRect(first).top - tester.getRect(find.byKey(const ValueKey('api-limit-0-0-label'))).bottom, closeTo(6, 0.1));
      } finally {
        semantics.dispose();
      }
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      final next = find.byKey(const ValueKey('api-limit-0-1'));
      expect(tester.widget<EditableText>(find.descendant(of: next, matching: find.byType(EditableText))).focusNode.hasFocus, true);
      if (width <= 390) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(const ValueKey('api-policy-save'))).bottom, lessThanOrEqualTo(600));
      }
      // Empty/editing values keep the label fixed, and invalid input must not save.
      final writes = store.writes;
      await tester.enterText(first, '');
      await tester.pump();
      expect(tester.getRect(first).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('api-policy-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('api-policy-error')), findsOneWidget);
      expect(store.writes, writes);
      // Saving remains a deliberate action; geometry must not change limit meanings.
      await tester.ensureVisible(first);
      await tester.enterText(find.byKey(const ValueKey('api-limit-0-0')), '41');
      await tester.ensureVisible(find.byKey(const ValueKey('api-policy-save')));
      await tester.tap(find.byKey(const ValueKey('api-policy-save')));
      await tester.pumpAndSettle();
      expect(api.state.policy.globalLimits.perSecond, 41);
      expect(container.read(integrationApiPublicationProvider).runtime!.policy.globalLimits.perSecond, 41);
      expect(server.epoch, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant({platform}));
  }
}
