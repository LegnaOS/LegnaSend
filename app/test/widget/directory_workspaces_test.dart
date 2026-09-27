import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/tabs/workspaces_tab.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/provider/workspace_password_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';
import '../unit/workspace/directory_publication_test.dart' show DirectoryTestServer, TestWorkspaceCatalog;
import '../unit/workspace/workspace_fixtures.dart';
import 'link_workspace_tags_test.dart' show TagNetwork;

void main() {
  for (final size in [const Size(390, 844), const Size(1040, 900)]) {
    testWidgets('directory create, publish, hide, close and destroy ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await LocaleSettings.setLocale(AppLocale.en);
      final temp = Directory.systemTemp.createTempSync('legnasend-workspace-widget-');
      final root = Directory('${temp.path}/资料 %20 #${Platform.isWindows ? '' : ' '}')..createSync();
      final original = File('${root.path}/source.txt')..writeAsStringSync('do not delete');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = TestWorkspaceCatalog(MemoryWorkspaceStore());
      final server = DirectoryTestServer();
      final settings = SettingsService(MockPersistenceService());
      final container = RefenaContainer(
        overrides: [
          workspaceCatalogProvider.overrideWithNotifier((_) => source),
          serverProvider.overrideWithNotifier((_) => server),
          workspacePasswordProvider.overrideWithValue((password) async {
            expect(password, 'test-password');
            return fixturePasswordHash;
          }),
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
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        // Directory probes and acknowledgement work are real asynchronous IO.
        await tester.runAsync(() async {
          await tester.tap(finder);
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
      }

      await tap(find.text(t.general.add));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), 'Design files');
      await tester.enterText(find.byType(TextField).at(1), 'api');
      await tester.enterText(find.byType(TextField).at(2), root.path);
      await tap(find.text(t.general.save));
      expect(find.text(t.directoryWorkspaces.invalidInput), findsOneWidget);
      expect(source.state.entries, isEmpty);
      await tester.enterText(find.byType(TextField).at(1), 'design');
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.enabled, false);
      expect(source.state.entries.single.source.locator, root.path);
      expect(find.text(t.directoryWorkspaces.closed), findsOneWidget);
      await tap(find.text(t.directoryWorkspaces.enable));
      expect(find.text(t.directoryWorkspaces.serving), findsOneWidget);
      expect(find.text('192.168.9.4'), findsOneWidget);
      expect(find.text('198.18.0.1'), findsOneWidget);
      expect(server.epoch, 9);
      expect(source.state.entries.single.allowUpload, false);
      await tap(find.text(t.directoryWorkspaces.uploadPermission));
      await tap(find.byKey(const ValueKey('workspace-upload-switch')));
      server.fail = true;
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.allowUpload, true);
      expect(find.text(t.directoryWorkspaces.uploadPending), findsOneWidget);
      server.fail = false;
      await tap(find.text(t.directoryWorkspaces.retry));
      expect(find.text(t.directoryWorkspaces.allowUpload), findsOneWidget);
      expect(server.requests.last['workspaces'][0]['allowUpload'], true);
      await tap(find.text(t.directoryWorkspaces.uploadPermission));
      await tap(find.byKey(const ValueKey('workspace-upload-switch')));
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.allowUpload, false);
      expect(server.requests.last['workspaces'][0]['allowUpload'], false);
      await tap(find.text(t.directoryWorkspaces.hide));
      expect(source.state.entries.single.visible, false);
      expect(find.text(t.directoryWorkspaces.hidden), findsOneWidget);
      await tap(find.text(t.directoryWorkspaces.access));
      await tap(find.byType(SwitchListTile));
      await tester.enterText(find.byType(TextField).at(0), 'test-password');
      await tester.enterText(find.byType(TextField).at(1), 'different');
      await tap(find.text(t.general.save));
      expect(find.text(t.directoryWorkspaces.passwordInvalid), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'test-password');
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.passwordHash, fixturePasswordHash);
      expect(find.text(t.directoryWorkspaces.protected), findsOneWidget);
      expect(server.requests.last['workspaces'][0]['passwordHash'], fixturePasswordHash);
      await tap(find.text(t.directoryWorkspaces.access));
      // Empty edit preserves the verifier, rather than hashing an empty value.
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.passwordHash, fixturePasswordHash);
      await tap(find.text(t.directoryWorkspaces.access));
      await tap(find.byType(SwitchListTile));
      server.fail = true;
      await tap(find.text(t.general.save));
      expect(source.state.entries.single.passwordHash, isNull);
      expect(find.text(t.directoryWorkspaces.accessPending), findsOneWidget);
      expect(find.text(t.directoryWorkspaces.openAccess), findsNothing);
      server.fail = false;
      await tap(find.text(t.directoryWorkspaces.retry));
      expect(find.text(t.directoryWorkspaces.openAccess), findsOneWidget);
      server.fail = true;
      await tap(find.text(t.directoryWorkspaces.close));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tap(find.text(t.general.confirm));
      expect(find.text(t.directoryWorkspaces.previousServing), findsOneWidget);
      expect(find.text(t.directoryWorkspaces.syncFailed), findsOneWidget);
      server.fail = false;
      await tap(find.text(t.directoryWorkspaces.retry));
      expect(find.text(t.directoryWorkspaces.closed), findsOneWidget);
      await tap(find.byTooltip(t.directoryWorkspaces.destroy));
      await tap(find.text(t.general.confirm));
      expect(source.state.entries, isEmpty);
      expect(original.readAsStringSync(), 'do not delete');
      expect(server.epoch, 9);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  }
}
