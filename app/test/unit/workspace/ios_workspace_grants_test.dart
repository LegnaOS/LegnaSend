import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/native/ios_workspace_grants.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../mocks.mocks.dart';
import 'directory_publication_test.dart' show DirectoryTestServer;
import 'workspace_fixtures.dart';
import 'workspace_test_persistence.dart';

class GrantCatalog extends WorkspaceCatalogNotifier {
  final MemoryWorkspaceStore store;
  GrantCatalog(this.store);
  @override
  WorkspaceCatalogState init() {
    catalog = WorkspaceCatalog(store: store, probe: probeWorkspaceDirectory, onChanged: (value) => state = value);
    return const WorkspaceCatalogState();
  }
}

class GrantServer extends DirectoryTestServer {
  Completer<bool>? stopping;
  @override
  Future<bool> get listenerStopBarrier => stopping?.future ?? Future.value(true);
  void beginStop() {
    stopping = Completer<bool>();
    epoch++;
    state = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('legnasend/ios_workspace');
  const bridge = IosWorkspaceGrants();
  final first = workspaceId(41), second = workspaceId(42), lease = workspaceId(90);
  late List<String> calls;
  late Set<String> held;
  late bool denied;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls = [];
    held = {};
    denied = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = (call.arguments as Map?) ?? {};
      switch (call.method) {
        case 'pick':
          return {'grantId': first, 'locator': '/external/$first'};
        case 'probe':
          if (denied) throw PlatformException(code: 'grantUnavailable');
          return '/external/${args['grantId']}';
        case 'acquire':
          held.addAll((args['grantIds'] as List).cast<String>());
          return {
            'leaseId': lease,
            'roots': {for (final id in held) id: '/external/$id'},
          };
        case 'retainOnly':
          held = (args['grantIds'] as List).cast<String>().toSet();
          return null;
        case 'release':
          held.clear();
          return null;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('fresh empty snapshot crosses acknowledgement fence; pre-ack in-flight read does not', () async {
    final queued = <Completer<String>>[];
    final activity = WebTransferActivityNotifier(
      loadSnapshot: () {
        final gate = Completer<String>();
        queued.add(gate);
        return gate.future;
      },
    );
    final container = RefenaContainer(overrides: [webTransferActivityProvider.overrideWithNotifier((_) => activity)]);
    addTearDown(container.disposeContainer);
    container.read(webTransferActivityProvider);
    activity.startPolling(generation: () => 1, isCurrent: () => true);
    queued.single.complete('[]');
    await Future<void>.delayed(Duration.zero);
    final firstRevision = activity.snapshotRevision;
    await Future<void>.delayed(const Duration(milliseconds: 520));
    expect(queued.length, 2);
    activity.requireFreshSnapshot();
    queued.last.complete('[]');
    await Future<void>.delayed(Duration.zero);
    expect(activity.snapshotRevision, firstRevision, reason: 'pre-ack read is not a fence');
    await Future<void>.delayed(const Duration(milliseconds: 520));
    expect(queued.length, 3);
    queued.last.complete('[]');
    await Future<void>.delayed(Duration.zero);
    expect(activity.snapshotRevision, firstRevision + 1, reason: 'identical but fresh empty result is consumed');
    expect(activity.confirmedIdle, true);
  });

  for (final fails in [false, true]) {
    test('actual stop barrier waits for native acknowledgement; failure=$fails', () async {
      final gate = Completer<String?>();
      final server = ServerService(stopListenerWithActivity: () => gate.future);
      final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
      addTearDown(container.disposeContainer);
      container.read(serverProvider);
      final stop = server.stopServer();
      final checked = expectLater(stop, fails ? throwsStateError : completes);
      await Future<void>.delayed(Duration.zero);
      var complete = false;
      final barrier = server.listenerStopBarrier.then((value) {
        complete = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(complete, false);
      if (fails) {
        gate.completeError(StateError('stop failed'));
      } else {
        gate.complete('[]');
      }
      await checked;
      expect(await barrier, !fails);
      expect(container.notifier(webTransferActivityProvider).confirmedIdle, !fails);
    });
  }

  test('iOS picker returns opaque grant; probe verifies exact root and revoked grants fail closed', () async {
    final source = (await bridge.pick())!;
    expect(source.kind, WorkspaceSourceKind.appleBookmark);
    expect(source.grantId, first);
    expect((await probeWorkspaceDirectory(source)).canonicalPath, '/external/$first');
    denied = true;
    expect((await probeWorkspaceDirectory(source)).invalidReason, WorkspaceInvalidReason.grantUnavailable);
    await expectLater(bridge.probe('../escape'), throwsFormatException);
  });

  test('macOS uses persisted Apple grants and never accepts a plain path as authority', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(bridge.supported, true);
    final source = (await bridge.pick())!;
    expect(source.kind, WorkspaceSourceKind.appleBookmark);
    expect(source.grantId, first);
    expect((await probeWorkspaceDirectory(source)).canonicalPath, '/external/$first');
    final active = await bridge.acquire([first]);
    expect(active!.roots, {first: '/external/$first'});
    await bridge.adopt(first);
    await bridge.prune([first]);
    final before = calls.length;
    await expectLater(bridge.probe('/Users/Shared/previous-directory'), throwsFormatException);
    expect(calls.length, before, reason: 'legacy path strings do not become bookmarks');
    denied = true;
    expect((await probeWorkspaceDirectory(source)).invalidReason, WorkspaceInvalidReason.grantUnavailable);
    expect(held, {first}, reason: 'a failed probe must not release an active publication lease');
    await bridge.release(active);
    expect(held, isEmpty);
  });

  test('non-Apple platforms keep their existing picker path and do not call the grant channel', () async {
    for (final platform in [TargetPlatform.android, TargetPlatform.linux, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(bridge.supported, false);
      await expectLater(bridge.pick(), throwsUnsupportedError);
      await bridge.prune([]);
    }
    expect(calls, isEmpty);
  });

  test('malformed native lease is rejected rather than accepting URI as root', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'acquire'
          ? {
              'leaseId': lease,
              'roots': {first: 'content://tree'},
            }
          : null;
    });
    await expectLater(bridge.acquire([first]), throwsFormatException);
    expect(calls, ['acquire', 'release']);
  });

  test('union lease survives replacement until explicit retain and release is idempotent native operation', () async {
    var active = await bridge.acquire([first]);
    active = await bridge.acquire([second], retaining: active);
    expect(active!.roots.keys.toSet(), {first, second});
    active = await bridge.retainOnly(active, [second]);
    expect(held, {second});
    await bridge.release(active);
    expect(held, isEmpty);
  });

  test('permission failure disables restored share; reauthorization stays closed until explicit enable', () async {
    final entry = workspace(1, enabled: true).copyWith(
      source: WorkspaceSource(kind: WorkspaceSourceKind.appleBookmark, locator: '/external/$first', grantId: first),
    );
    final catalog = WorkspaceCatalog(store: MemoryWorkspaceStore([entry]), probe: probeWorkspaceDirectory);
    denied = true;
    await catalog.initialize();
    expect(catalog.state.entries.single.enabled, false);
    expect(catalog.state.entries.single.invalidReason, WorkspaceInvalidReason.grantUnavailable);
    denied = false;
    await catalog.update(
      entry.id,
      source: entry.source.copyWith(grantId: second, locator: '/external/$second'),
    );
    expect(catalog.state.entries.single.enabled, false);
    await catalog.enable(entry.id);
    expect(catalog.state.publishable.single.source.grantId, second);
    catalog.dispose();
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    test('${platform.name} publication holds scope through failed close, stop failure and late disk publication', () async {
      debugDefaultTargetPlatformOverride = platform;
      final entry = workspace(1, enabled: true).copyWith(
        source: WorkspaceSource(kind: WorkspaceSourceKind.appleBookmark, locator: '/external/$first', grantId: first),
      );
      final catalog = GrantCatalog(MemoryWorkspaceStore([entry]));
      final server = GrantServer();
      final container = RefenaContainer(
        overrides: [
          persistenceProvider.overrideWithValue(MemoryWorkspacePersistence()),
          workspaceCatalogProvider.overrideWithNotifier((_) => catalog),
          serverProvider.overrideWithNotifier((_) => server),
          settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
          parentIsolateProvider.overrideWithNotifier(
            (_) => IsolateController(
              initialState: ParentIsolateState.initial(
                SyncState(
                  rootIsolateToken: Object(),
                  securityContext: const StoredSecurityContext(privateKey: 'key', publicKey: 'public', certificate: 'cert', certificateHash: 'hash'),
                  deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Fixture', androidSdkInt: null),
                  alias: 'Fixture',
                  port: 53317,
                  discoveryPort: 53317,
                  networkWhitelist: null,
                  networkBlacklist: null,
                  protocol: ProtocolType.http,
                  multicastGroup: '224.0.0.167',
                  discoveryTimeout: 1000,
                  serverRunning: false,
                  download: false,
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.disposeContainer);
      container.notifier(workspaceCatalogProvider);
      await catalog.catalog.initialize();
      final publisher = container.notifier(directoryPublicationProvider);
      final activity = container.notifier(webTransferActivityProvider);
      await publisher.synchronize();
      expect(held, {first});
      server.fail = true;
      await catalog.catalog.disable(entry.id);
      await publisher.synchronize();
      expect(publisher.state.failed, true);
      expect(held, {first});
      server.fail = false;
      await publisher.synchronize();
      expect(publisher.state.published, isEmpty);
      expect(held, {first}, reason: 'ack alone does not drain publication workers');
      final row = {
        'id': 'late',
        'name': 'file',
        'peer': '',
        'total': 1,
        'transferred': 1,
        'direction': 'receive',
        'operation': 'upload',
        'origin': 'browser',
        'workspaceId': entry.id,
        'workspaceName': entry.name,
      };
      activity.apply(
        jsonEncode([
          {...row, 'phase': 'transferring'},
        ]),
        generation: server.epoch,
      );
      await publisher.synchronize();
      expect(held, {first});
      server.beginStop();
      activity.beginStop(generation: server.epoch);
      final pending = publisher.synchronize();
      await Future<void>.delayed(Duration.zero);
      expect(held, {first});
      server.stopping!.complete(false);
      await pending;
      activity.stopped(
        generation: server.epoch,
        finalSnapshot: jsonEncode([
          {...row, 'phase': 'succeeded'},
        ]),
      );
      await publisher.synchronize();
      expect(held, {first}, reason: 'actual stop failed');
      server.stopping = Completer<bool>()..complete(true);
      activity.beginStop(generation: server.epoch);
      await publisher.synchronize();
      expect(held, {first}, reason: 'no valid final observation yet');
      activity.stopped(
        generation: server.epoch,
        finalSnapshot: jsonEncode([
          {...row, 'id': 'late2', 'phase': 'transferring'},
        ]),
      );
      await publisher.synchronize();
      expect(held, {first});
      // Previous success is immutable and therefore sufficient even if an old
      // snapshot is replayed. Exercise fresh pending identity for the late gate.
      activity.apply(
        jsonEncode([
          {...row, 'id': 'late2', 'phase': 'transferring'},
        ]),
        generation: server.epoch,
      );
      await publisher.synchronize();
      activity.apply(
        jsonEncode([
          {...row, 'id': 'late2', 'phase': 'succeeded'},
        ]),
        generation: server.epoch,
      );
      await publisher.synchronize();
      expect(held, isEmpty);
    });
  }
}
