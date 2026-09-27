import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/pages/tabs/workspaces_tab.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import '../mocks.mocks.dart';
import '../unit/workspace/directory_publication_test.dart' show DirectoryTestServer, TestWorkspaceCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('batch selection confirms independent workspace policy and closes only selection ${locale.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final temp = Directory.systemTemp.createTempSync('legna-batch-widget-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final entries = [
        for (var i = 1; i <= 2; i++)
          workspace(i, enabled: true, visible: i == 2).copyWith(
            source: WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: (Directory('${temp.path}/$i')..createSync()).path),
          ),
      ];
      final source = TestWorkspaceCatalog(MemoryWorkspaceStore(entries)), server = DirectoryTestServer();
      final settings = SettingsService(MockPersistenceService());
      final container = RefenaContainer(
        overrides: [
          workspaceCatalogProvider.overrideWithNotifier((_) => source),
          serverProvider.overrideWithNotifier((_) => server),
          localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
        ],
      );
      addTearDown(container.disposeContainer);
      container.notifier(workspaceCatalogProvider);
      await tester.runAsync(source.catalog.initialize);
      await tester.runAsync(container.notifier(directoryPublicationProvider).synchronize);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(home: Scaffold(body: WorkspacesTab())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-batch-select')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('workspace-select-${entries.first.id}')));
      await tester.tap(find.byKey(ValueKey('workspace-select-${entries.first.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('workspace-batch-close')));
      await tester.tap(find.byKey(const ValueKey('workspace-batch-close')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(entries.first.name)), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(entries.last.name)), findsNothing);
      await tester.tap(find.text(t.general.confirm));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(source.state.entries.first.enabled, false);
      expect(source.state.entries.last.enabled, true);
      expect(container.read(serverProvider), isNotNull);
      expect(container.read(directoryPublicationProvider).published.containsKey(entries.first.id), false);
      expect(container.read(directoryPublicationProvider).published.containsKey(entries.last.id), true);
      expect(tester.takeException(), isNull);
    });
  }
}
