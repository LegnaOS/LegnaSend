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
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';
import '../unit/workspace/directory_publication_test.dart' show DirectoryTestServer;
import '../unit/workspace/ios_workspace_grants_test.dart' show GrantCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import '../unit/workspace/workspace_test_persistence.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('${platform.name} restores an existing invalid workspace without recreation', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await LocaleSettings.setLocale(AppLocale.en);
      final original = workspace(72).copyWith(
        name: 'Keep name',
        slug: 'keep-link',
        visible: false,
        passwordHash: fixturePasswordHash,
        allowUpload: true,
        invalidReason: WorkspaceInvalidReason.permissionDenied,
        source: const WorkspaceSource(kind: WorkspaceSourceKind.directory, locator: '/old/restricted'),
      );
      final grant = workspaceId(91), lease = workspaceId(92);
      var cancelled = true;
      const channel = MethodChannel('legnasend/ios_workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'pick' => cancelled ? null : {'grantId': grant, 'locator': '/selected/authorized'},
          'probe' => '/selected/authorized',
          'acquire' => {
            'leaseId': lease,
            'roots': {grant: '/selected/authorized'},
          },
          _ => null,
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final source = GrantCatalog(MemoryWorkspaceStore([original]));
      final settings = SettingsService(MockPersistenceService());
      final server = DirectoryTestServer();
      final container = RefenaContainer(
        overrides: [
          persistenceProvider.overrideWithValue(MemoryWorkspacePersistence()),
          workspaceCatalogProvider.overrideWithNotifier((_) => source),
          serverProvider.overrideWithNotifier((_) => server),
          localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
        ],
      );
      addTearDown(container.disposeContainer);
      container.notifier(workspaceCatalogProvider);
      await tester.runAsync(source.catalog.initialize);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(home: Scaffold(body: WorkspacesTab())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final restore = find.byKey(ValueKey('workspace-restore-${original.id}'));
      Future<void> pick() async {
        await tester.ensureVisible(restore);
        await tester.runAsync(() async {
          await tester.tap(restore);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        await tester.pumpAndSettle();
      }

      await pick();
      expect(source.state.entries.single.source, original.source);
      expect(source.state.entries.single.enabled, false);
      cancelled = false;
      await pick();
      final updated = source.state.entries.single;
      expect(updated.id, original.id);
      expect(updated.name, original.name);
      expect(updated.slug, original.slug);
      expect(updated.passwordHash, original.passwordHash);
      expect(updated.visible, false);
      expect(updated.allowUpload, true);
      expect(updated.enabled, true);
      expect(updated.source.grantId, grant);
      expect(find.byKey(ValueKey('workspace-restore-${original.id}')), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final width in [390.0, 1024.0]) {
      testWidgets('${platform.name} folder picker creates closed bookmark workspace at $width', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
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
            persistenceProvider.overrideWithValue(MemoryWorkspacePersistence()),
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
}
