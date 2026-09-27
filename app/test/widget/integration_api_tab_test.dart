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
import 'package:localsend_app/util/api/api_quota_strings.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';
import '../unit/api/api_fixtures.dart';
import '../unit/workspace/directory_publication_test.dart' show TestWorkspaceCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

void main() {
  for (final layout in [(390.0, 1.0), (1040.0, 1.0), (390.0, 1.6)]) {
    final (width, scale) = layout;
    for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhHk, AppLocale.de]) {
      if (scale > 1 && locale == AppLocale.de) continue;
      testWidgets(
        'API real intent, one-time key modal and failed revocation $width ${locale.languageTag} scale=$scale',
        (tester) async {
          final size = Size(width, 900);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.runAsync(() => LocaleSettings.setLocale(locale));
          final store = MemoryApiStore(), factory = FakeApiFactory(), server = ApiTestServer();
          final source = TestWorkspaceCatalog(MemoryWorkspaceStore());
          final settings = SettingsService(MockPersistenceService());
          final container = RefenaContainer(
            overrides: [
              integrationApiSettingsProvider.overrideWithNotifier((_) => IntegrationApiSettingsNotifier(store: store)),
              integrationApiValidatorProvider.overrideWithValue((_) async {}),
              integrationApiKeyFactoryProvider.overrideWithValue(factory.call),
              serverProvider.overrideWithNotifier((_) => server),
              localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
              workspaceCatalogProvider.overrideWithNotifier((_) => source),
            ],
          );
          addTearDown(container.disposeContainer);
          final api = container.notifier(integrationApiSettingsProvider);
          await api.initialize();
          await container.notifier(integrationApiPublicationProvider).synchronize();
          final paint = GlobalKey();
          final capture = Platform.environment['LEGNASEND_API_SCREENSHOTS'];
          if (capture != null) {
            await tester.runAsync(() async {
              await (FontLoader('ApiTest')..addFont(rootBundle.load('packages/yaru/assets/fonts/Ubuntu-R.ttf'))).load();
              await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
              final fontPath = Platform.environment['LEGNASEND_API_CJK_FONT'];
              if (fontPath != null) {
                final bytes = await File(fontPath).readAsBytes();
                await (FontLoader('ApiCJK')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
              }
            });
          }
          final brightness = locale == AppLocale.en ? Brightness.light : Brightness.dark;
          var theme = getTheme(ColorMode.localsend, const Color(0xff54b865), brightness, null);
          if (capture != null) {
            theme = theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'ApiTest', fontFamilyFallback: ['ApiCJK']),
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
                    supportedLocales: const [Locale('en'), Locale('zh', 'CN'), Locale('zh', 'HK'), Locale('de')],
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    locale: locale.flutterLocale,
                    theme: theme,
                    home: const Scaffold(body: ApiTab()),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (locale == AppLocale.de) expect(find.text(t.integrationApi.fallback), findsOneWidget);
          Future<void> tap(Finder finder) async {
            await tester.ensureVisible(finder);
            await tester.tap(finder);
            await tester.pumpAndSettle();
          }

          await tap(find.byKey(const ValueKey('api-enable')));
          expect(api.state.policy.enabled, true);
          expect(container.read(integrationApiPublicationProvider).runtime!.policy.enabled, true);
          expect(find.textContaining('192.168.9.4:54199'), findsOneWidget);
          expect(find.textContaining('198.18.0.1:54199'), findsOneWidget);
          expect(server.epoch, 1);
          if (capture != null) {
            await tester.runAsync(() async {
              final boundary = paint.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              final folder = Directory(capture)..createSync(recursive: true);
              File(
                '${folder.path}/api-${width.toInt()}-${locale.languageTag}${scale > 1 ? '-large' : ''}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tap(find.byKey(const ValueKey('api-auth')));
          expect(find.byType(AlertDialog), findsOneWidget);
          await tap(find.text(t.general.cancel));
          expect(api.state.policy.authRequired, true);
          await tap(find.byKey(const ValueKey('api-create')));
          await tester.enterText(find.byKey(const ValueKey('api-key-name')), 'Automation');
          expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('api-scope-upload'))).value, false);
          await tap(find.byKey(const ValueKey('api-scope-upload')));
          for (final scope in ApiScope.values.where((s) => s.requiresGlobal)) {
            expect(tester.widget<CheckboxListTile>(find.byKey(ValueKey('api-scope-${scope.name}'))).value, false);
          }
          await tap(find.byKey(const ValueKey('api-scope-transfersSend')));
          expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('api-scope-manage'))).value, false);
          await tap(find.byKey(const ValueKey('api-scope-manage')));
          await tap(find.byKey(const ValueKey('api-all-workspaces')));
          store.fail = true;
          await tap(find.byKey(const ValueKey('api-generate-confirm')));
          expect(find.byKey(const ValueKey('api-key-error')), findsOneWidget);
          expect(tester.widget<TextField>(find.byKey(const ValueKey('api-key-name'))).controller!.text, 'Automation');
          expect(factory.drafts.single.reads, 0);
          store.fail = false;
          await tap(find.byKey(const ValueKey('api-generate-confirm')));
          expect(find.byKey(const ValueKey('api-created-secret')), findsOneWidget);
          final secret = factory.drafts.last.secret;
          expect(find.text(secret), findsOneWidget);
          expect(store.raw, isNot(contains(secret)));
          expect(factory.drafts.last.reads, 1);
          await tap(find.text(t.integrationApi.close));
          expect(find.text(secret), findsNothing);
          expect(api.state.keys.single.name, 'Automation');
          expect(api.state.keys.single.grant.scopes, contains(ApiScope.upload));
          expect(api.state.keys.single.grant.scopes, contains(ApiScope.manage));
          expect(api.state.keys.single.grant.scopes, contains(ApiScope.transfersSend));
          final keyId = api.state.keys.single.id;
          final copy = ApiQuotaStrings(locale.languageTag);
          await tap(find.byKey(ValueKey('api-key-toggle-$keyId')));
          await tap(find.text(t.general.cancel));
          expect(api.state.keys.single.enabled, true);
          await tap(find.byKey(ValueKey('api-key-toggle-$keyId')));
          await tap(find.text(t.general.confirm));
          expect(api.state.keys.single.enabled, false);
          expect(find.text(copy.paused), findsOneWidget);
          await tap(find.byKey(ValueKey('api-key-toggle-$keyId')));
          store.fail = true;
          await tap(find.text(t.general.confirm));
          expect(api.state.keys.single.enabled, false);
          store.fail = false;
          await tap(find.byKey(ValueKey('api-key-toggle-$keyId')));
          await tap(find.text(t.general.confirm));
          expect(api.state.keys.single.enabled, true);
          expect(api.state.keys.single.id, keyId);
          await tap(find.byKey(ValueKey('api-key-limits-$keyId')));
          expect(find.text(copy.zeroHint), findsWidgets);
          await tap(find.byKey(const ValueKey('api-key-inherit')));
          await tester.enterText(find.byKey(const ValueKey('api-key-limit-0')), '1001');
          await tap(find.byKey(const ValueKey('api-key-limits-save')));
          expect(find.byKey(const ValueKey('api-key-limits-error')), findsOneWidget);
          for (var i = 0; i < 3; i++) {
            await tester.enterText(find.byKey(ValueKey('api-key-limit-$i')), '0');
          }
          store.fail = true;
          await tap(find.byKey(const ValueKey('api-key-limits-save')));
          expect(find.byKey(const ValueKey('api-key-limits-error')), findsOneWidget);
          expect(api.state.keys.single.limits, isNull);
          store.fail = false;
          await tap(find.byKey(const ValueKey('api-key-limits-save')));
          expect(api.state.keys.single.limits!.perSecond, 0);
          expect(api.state.keys.single.limits!.perMinute, 0);
          expect(api.state.keys.single.limits!.concurrent, 0);
          await tap(find.byKey(ValueKey('api-key-limits-$keyId')));
          await tap(find.byKey(const ValueKey('api-key-inherit')));
          await tap(find.byKey(const ValueKey('api-key-limits-save')));
          expect(api.state.keys.single.limits, isNull);
          expect(tester.takeException(), isNull);
          server.fail = true;
          await tap(find.byKey(ValueKey('api-revoke-${api.state.keys.single.id}')));
          await tap(find.text(t.general.confirm));
          expect(api.state.keys, isEmpty);
          expect(container.read(integrationApiPublicationProvider).failed, true);
          expect(find.text(t.integrationApi.removedLive), findsOneWidget);
          server.fail = false;
          await tap(find.text(t.integrationApi.refresh));
          expect(container.read(integrationApiPublicationProvider).runtime!.keyIds, isEmpty);
          expect(find.text(t.integrationApi.removedLive), findsNothing);
          await tap(find.text(t.integrationApi.editPolicy));
          expect(find.byKey(const ValueKey('api-scope-upload')), findsNothing);
          expect(find.byKey(const ValueKey('api-scope-manage')), findsNothing);
          for (final scope in ApiScope.values.where((s) => s.requiresGlobal)) {
            expect(find.byKey(ValueKey('api-scope-${scope.name}')), findsNothing);
          }
          await tester.enterText(find.byKey(const ValueKey('api-limit-0-0')), '1001');
          await tap(find.byKey(const ValueKey('api-policy-save')));
          expect(find.text(t.integrationApi.invalid), findsOneWidget);
          await tester.enterText(find.byKey(const ValueKey('api-limit-0-0')), '11');
          store.fail = true;
          await tap(find.byKey(const ValueKey('api-policy-save')));
          expect(find.byKey(const ValueKey('api-policy-error')), findsOneWidget);
          expect(tester.widget<TextField>(find.byKey(const ValueKey('api-limit-0-0'))).controller!.text, '11');
          store.fail = false;
          await tap(find.byKey(const ValueKey('api-policy-save')));
          expect(api.state.policy.globalLimits.perSecond, 11);
          expect(container.read(integrationApiPublicationProvider).runtime!.policy.globalLimits.perSecond, 11);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
      );
    }
  }
}
