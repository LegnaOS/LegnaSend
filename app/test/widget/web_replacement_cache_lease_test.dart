import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/web_shared_files_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../fixtures/web_file_management_fixture.dart';
import '../mocks.mocks.dart';

void main() {
  testWidgets('replacement retains cache lease through picker, confirmation and server acknowledgement', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final picker = Completer<List<CrossFile>>();
    final publication = Completer<void>();
    final server = ManagedFileServer(count: 1);
    final container = RefenaContainer(
      overrides: [
        serverProvider.overrideWithNotifier((_) => server),
        settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
        webFilePublisherProvider.overrideWithValue((_, _) => publication.future),
        webReplacementPickerProvider.overrideWithValue((_) => picker.future),
      ],
    );
    addTearDown(container.disposeContainer);
    final caches = container.read(sourceCacheLeaseProvider);
    Future<void> protected() async {
      var cleaned = false;
      await caches.cleanIfIdle(
        inUse: () => false,
        cleanup: () async {
          cleaned = true;
        },
      );
      expect(cleaned, false);
    }

    await tester.pumpWidget(
      RefenaScope.withContainer(
        ownsContainer: false,
        container: container,
        child: TranslationProvider(child: const MaterialApp(home: WebSharedFilesPage(generation: 7))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('replace-file-0')));
    await tester.pump();
    await protected();
    picker.complete([queuedFile('replacement', 10).copyWith(path: '/cache/replacement.bin')]);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await protected();
    await tester.tap(find.byKey(const ValueKey('confirm-file-change')));
    await tester.pump();
    await protected();
    // Route disposal is independent from the operation's source lifetime.
    await tester.pumpWidget(const SizedBox());
    await protected();
    publication.complete();
    await tester.pumpAndSettle();
    expect(caches.activeLeases, 0);
    expect(server.state!.webDownloadState!.files.values.single.path, '/cache/replacement.bin');
    expect(tester.takeException(), isNull);
  });
}
