import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import '../../fixtures/transfer_fixtures.dart';
import '../../fixtures/web_file_management_fixture.dart';
import '../../mocks.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RefenaContainer fixture(ManagedFileServer server, WebFilePublisher publisher) {
    final container = RefenaContainer(
      overrides: [
        serverProvider.overrideWithNotifier((_) => server),
        settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
        webFilePublisherProvider.overrideWithValue(publisher),
      ],
    );
    addTearDown(container.disposeContainer);
    container.read(serverProvider);
    return container;
  }

  test('publish before dropping old target, preserve progress, permission, port and share identity', () async {
    final server = ManagedFileServer(), arrived = Completer<void>(), release = Completer<void>();
    String? replacement;
    fixture(server, (added, removed) async {
      expect(removed, ['file-0']);
      replacement = added.keys.single;
      expect(replacement, isNot('file-0'));
      expect(server.state!.webDownloadState!.files.keys, containsAll(['file-0', replacement]));
      arrived.complete();
      await release.future;
    });
    final operation = server.patchWebFiles(
      expectedGeneration: 7,
      removeFileIds: ['file-0'],
      replacements: [queuedFile('replacement', 10).copyWith(path: '/picked/new.bin')],
    );
    await arrived.future;
    server.receiveUpdate();
    release.complete();
    expect(await operation, isTrue);
    expect(server.state!.webDownloadState!.files.keys, unorderedEquals([replacement, 'file-1', 'file-2']));
    expect(server.state!.session!.sessionId, 'updated-receive');
    expect(server.state!.port, 53318);
    expect(server.state!.https, false);
    expect(server.generation, 7);
    expect((server.state!.web! as WebShareDownload).allowUpload, true);
  });

  test('failed publication rolls back only new targets and a subsequent request succeeds', () async {
    final server = ManagedFileServer(), arrived = Completer<void>(), release = Completer<void>();
    var calls = 0;
    fixture(server, (added, removed) async {
      if (calls++ == 0) {
        arrived.complete();
        await release.future;
      }
    });
    final before = server.state!.webDownloadState!.files;
    final operation = server.patchWebFiles(expectedGeneration: 7, removeFileIds: ['file-0'], replacements: [queuedFile('replacement', 10)]);
    final assertion = expectLater(operation, throwsStateError);
    await arrived.future;
    server.receiveUpdate();
    release.completeError(StateError('publisher failed'));
    await assertion;
    expect(server.state!.webDownloadState!.files, before);
    expect(server.state!.session!.sessionId, 'updated-receive');
    expect(await server.patchWebFiles(expectedGeneration: 7, removeFileIds: ['file-1']), isTrue);
    expect(server.state!.webDownloadState!.files.keys, unorderedEquals(['file-0', 'file-2']));
  });

  test('stale generations, duplicate, absent and empty selections never reach publisher', () async {
    final server = ManagedFileServer();
    var calls = 0;
    fixture(server, (_, _) async {
      calls++;
    });
    expect(await server.patchWebFiles(expectedGeneration: 6, removeFileIds: ['file-0']), false);
    for (final selection in <List<String>>[
      [],
      ['absent'],
      ['file-0', 'file-0'],
      ['file-0', 'absent'],
    ]) {
      expect(await server.patchWebFiles(expectedGeneration: 7, removeFileIds: selection), false);
    }
    expect(calls, 0);
    expect(server.state!.webDownloadState!.files.length, 3);
  });

  test('late acknowledgement never edits a newly opened share', () async {
    final server = ManagedFileServer(), arrived = Completer<void>(), release = Completer<void>();
    fixture(server, (_, _) async {
      arrived.complete();
      await release.future;
    });
    final operation = server.patchWebFiles(expectedGeneration: 7, removeFileIds: ['file-0']);
    await arrived.future;
    server.changeShare();
    release.complete();
    expect(await operation, isFalse);
    expect(server.state!.webDownloadState!.files.length, 3);
    expect(server.generation, 8);
  });
}
