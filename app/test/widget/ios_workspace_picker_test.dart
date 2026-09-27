import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../unit/workspace/directory_publication_test.dart' show DirectoryTestServer;
import '../unit/workspace/ios_workspace_grants_test.dart' show GrantCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

void main() {
  for (final width in [390.0, 1024.0]) {
    testWidgets('iOS folder picker creates closed bookmark workspace at $width', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await LocaleSettings.setLocale(AppLocale.en);
      final id = workspaceId(91);
      final calls = <String>[];
      const channel = MethodChannel('legnasend/ios_workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'pick' => {'grantId': id, 'locator': '/external/Documents'},
          'probe' => '/external/Documents',
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final catalog = GrantCatalog(MemoryWorkspaceStore());
      final server = DirectoryTestServer();
      final settings = SettingsService(MockPersistenceService());
      final container = RefenaContainer(
        overrides: [
          workspaceCatalogProvider.overrideWithNotifier((_) => catalog),
          serverProvider.overrideWithNotifier((_) => server),
          localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
        ],
      );
      addTearDown(container.disposeContainer);
      container.notifier(workspaceCatalogProvider);
      await tester.runAsync(catalog.catalog.initialize);
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
      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.runAsync(() async {
          await tester.tap(target);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await tap(find.text(t.general.add));
      await tester.enterText(find.byType(TextField).at(0), 'Files provider');
      await tester.enterText(find.byType(TextField).at(1), 'ios-files');
      expect(tester.widget<TextField>(find.byType(TextField).at(2)).readOnly, true);
      await tap(find.byTooltip(t.directoryWorkspaces.choose));
      expect(find.text('/external/Documents'), findsOneWidget);
      await tap(find.text(t.general.save));
      expect(catalog.state.entries.single.source.kind, WorkspaceSourceKind.appleBookmark);
      expect(catalog.state.entries.single.source.grantId, id);
      expect(catalog.state.entries.single.enabled, false);
      expect(calls, contains('adopt'));
      expect(calls, isNot(contains('acquire')), reason: 'saving does not open the share');
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
