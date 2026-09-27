import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/pages/workspace_sources_page.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/api/api_source_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/workspace/directory_publication_test.dart' show TestWorkspaceCatalog;
import '../unit/workspace/workspace_fixtures.dart';

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhHk]) {
    testWidgets(
      'source approval requires local confirmation and reversible revoke ${locale.languageTag}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        final store = MemoryWorkspaceStore();
        // Use a single injected durable store so failed writes exercise the real catalog path.
        final actual = TestWorkspaceCatalog(store);
        final container = RefenaContainer(overrides: [workspaceCatalogProvider.overrideWithNotifier((_) => actual)]);
        addTearDown(container.disposeContainer);
        container.notifier(workspaceCatalogProvider);
        await actual.catalog.initialize();
        String? picked;
        var pickCalls = 0;
        final text = ApiSourceStrings(locale.languageTag);
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: const [Locale('en'), Locale('zh', 'CN'), Locale('zh', 'HK')],
                locale: locale.flutterLocale,
                theme: getTheme(ColorMode.localsend, const Color(0xff54b865), Brightness.dark, null),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.35)),
                  child: child!,
                ),
                home: WorkspaceSourcesPage(
                  pickDirectory: () async {
                    pickCalls++;
                    return picked;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        }

        final approve = find.byKey(const ValueKey('approve-workspace-source'));
        await tap(approve);
        expect(pickCalls, 1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(actual.state.approvedSources, isEmpty);
        picked = defaultTargetPlatform == TargetPlatform.android
            ? 'content://com.android.externalstorage.documents/tree/primary%3ADownload'
            : '/Users/local/Downloads/Shared folder';
        await tap(approve);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(picked), findsOneWidget);
        await tap(find.text(text.cancel));
        expect(actual.state.approvedSources, isEmpty);
        await tap(approve);
        await tester.enterText(find.byKey(const ValueKey('approved-source-name')), '');
        await tap(find.byKey(const ValueKey('approved-source-confirm')));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(actual.state.approvedSources, isEmpty);
        await tester.enterText(find.byKey(const ValueKey('approved-source-name')), 'Team documents');
        store.failWrite = true;
        await tap(find.byKey(const ValueKey('approved-source-confirm')));
        expect(actual.state.approvedSources, isEmpty);
        expect(find.text(text.failed), findsOneWidget);
        store.failWrite = false;
        await tap(approve);
        await tester.enterText(find.byKey(const ValueKey('approved-source-name')), 'Team documents');
        await tap(find.byKey(const ValueKey('approved-source-confirm')));
        expect(actual.state.approvedSources.single.name, 'Team documents');
        expect(actual.state.approvedSources.single.source.locator, picked);
        expect(
          actual.state.approvedSources.single.source.kind,
          defaultTargetPlatform == TargetPlatform.android ? WorkspaceSourceKind.androidTree : WorkspaceSourceKind.directory,
        );
        expect(actual.state.entries, isEmpty); // Approval does not create or enable a workspace.
        final id = actual.state.approvedSources.single.id;
        expect(find.text(id), findsOneWidget);
        await tap(find.byTooltip(text.revoke));
        await tap(find.text(text.cancel));
        expect(actual.state.approvedSources.single.id, id);
        store.failWrite = true;
        await tap(find.byTooltip(text.revoke));
        await tap(find.text(text.confirm));
        expect(actual.state.approvedSources.single.id, id);
        store.failWrite = false;
        await tap(find.byTooltip(text.revoke));
        await tap(find.text(text.confirm));
        expect(actual.state.approvedSources, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
}
