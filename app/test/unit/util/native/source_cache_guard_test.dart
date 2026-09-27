import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../../fixtures/transfer_fixtures.dart';
import '../../../fixtures/web_file_management_fixture.dart';

class _SharedOnly extends ManagedFileServer {
  @override
  ServerState init() => super.init().copyWith(session: null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only Android picker implements scoped deletion; iOS blanket tmp deletion is never eligible', () {
    for (final platform in TargetPlatform.values) {
      expect(supportsScopedPickerCacheCleanup(platform), platform == TargetPlatform.android);
    }
  });

  test('nested producers block deletion and idempotent release restores eligibility', () async {
    final guard = SourceCacheCoordinator();
    final a = await guard.acquire(), b = await guard.acquire();
    var calls = 0;
    Future<void> clean() async {
      calls++;
    }

    expect(await guard.cleanIfIdle(inUse: () => false, cleanup: clean), false);
    a.release();
    a.release();
    expect(guard.activeLeases, 1);
    expect(await guard.cleanIfIdle(inUse: () => false, cleanup: clean), false);
    b.release();
    expect(await guard.cleanIfIdle(inUse: () => true, cleanup: clean), false);
    expect(await guard.cleanIfIdle(inUse: () => false, cleanup: clean), true);
    expect(calls, 1);
  });

  test('a producer waits for actual deletion before creating its new source on disk', () async {
    final dir = await Directory.systemTemp.createTemp('legnasend-cache-lease-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/owned-source');
    await file.writeAsString('old cache');
    final guard = SourceCacheCoordinator(), release = Completer<void>();
    final cleaning = guard.cleanIfIdle(
      inUse: () => false,
      cleanup: () async {
        await release.future;
        await file.delete();
      },
    );
    var acquired = false;
    final producer = guard.withLease(() async {
      acquired = true;
      await file.writeAsString('new source');
    });
    await Future<void>.delayed(Duration.zero);
    expect(acquired, false);
    expect(await guard.cleanIfIdle(inUse: () => false, cleanup: () async => fail('duplicate cleanup')), false);
    release.complete();
    expect(await cleaning, true);
    await producer;
    expect(await file.readAsString(), 'new source');
    expect(guard.activeLeases, 0);
  });

  test('cleanup and conversion failures release leases without poisoning later acquisition', () async {
    final guard = SourceCacheCoordinator(), release = Completer<void>();
    final cleanup = guard.cleanIfIdle(
      inUse: () => false,
      cleanup: () async {
        await release.future;
        throw FileSystemException('fixture failure');
      },
    );
    final checked = expectLater(cleanup, throwsA(isA<FileSystemException>()));
    final lease = guard.acquire();
    release.complete();
    await checked;
    (await lease).release();
    await expectLater(guard.withLease<void>(() async => throw StateError('converter failed')), throwsStateError);
    expect(guard.activeLeases, 0);
    expect(await guard.cleanIfIdle(inUse: () => false, cleanup: () async {}), true);
  });

  test('actual selection action holds lease through converter and committed state', () async {
    var bulk = 0, registered = 0;
    final gate = Completer<CrossFile>(), started = Completer<void>();
    final container = RefenaContainer(
      overrides: [
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {
          registered++;
        }),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
          bulk++;
        }),
      ],
    );
    addTearDown(container.disposeContainer);
    final guard = container.read(sourceCacheLeaseProvider);
    final importing = container
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction(
            files: ['cached'],
            converter: (_) {
              expect(guard.activeLeases, 1);
              started.complete();
              return gate.future;
            },
          ),
        );
    await started.future;
    await container.global.dispatchAsync(ClearCacheAction());
    expect(bulk, 0);
    gate.complete(queuedFile('cached', 12));
    await importing;
    expect(guard.activeLeases, 0);
    expect(container.read(selectedSendingFilesProvider), hasLength(1));
    await container.global.dispatchAsync(ClearCacheAction());
    expect(bulk, 0);
    expect(registered, 2);
  });

  test('failed selection releases its action lease and permits a later cleanup', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    await expectLater(
      container
          .redux(selectedSendingFilesProvider)
          .dispatchAsync(
            AddFilesAction<String>(
              files: ['bad'],
              converter: (_) async => throw StateError('bad metadata'),
            ),
          ),
      throwsStateError,
    );
    expect(container.read(sourceCacheLeaseProvider).activeLeases, 0);
    expect(container.read(selectedSendingFilesProvider), isEmpty);
  });

  test('web-shared files remain protected even after selection and native sessions are empty', () async {
    var bulk = 0, registered = 0;
    final container = RefenaContainer(
      overrides: [
        serverProvider.overrideWithNotifier((_) => _SharedOnly()),
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {
          registered++;
        }),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
          bulk++;
        }),
      ],
    );
    addTearDown(container.disposeContainer);
    await container.global.dispatchAsync(ClearCacheAction());
    expect(registered, 1);
    expect(bulk, 0);
  });
}
