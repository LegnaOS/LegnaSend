import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/util/native/send_recovery_init.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

import '../../../fixtures/transfer_fixtures.dart';
import '../../../mocks.mocks.dart';

class _Isolates extends Mock implements IsolateController {}

class _Discovery extends NearbyDevicesService {
  final Device device;
  _Discovery(this.device)
    : super(isolateController: _Isolates(), favoriteService: FavoritesService(MockPersistenceService()), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {device.fingerprint: device}, signalingDevices: {});
}

/// A boundary-test spy, not wire or successful transfer evidence.
class _Sender extends SendNotifier {
  final ids = <String>[];
  final Completer<void>? held;
  _Sender({this.held});
  @override
  Future<void> startSession({
    required Device target,
    required List<CrossFile> files,
    required bool background,
    String? requestedSessionId,
    bool retainSession = false,
    LocalSendRoute? localRoute,
    List<String>? resumeKeys,
  }) async {
    ids.add(requestedSessionId!);
    state = {...state, requestedSessionId: outgoing(requestedSessionId, status: SessionStatus.declined).copyWith(target: target)};
    await held?.future;
  }

  @override
  Future<void> releaseRemoteSession(String sessionId) async {}
  @override
  Future<void> cancelSessionAndWait(String sessionId) async {
    if (held != null && !held!.isCompleted) held!.complete();
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Recovery provider did not reach expected state');
}

void main() {
  late Directory temp;
  final containers = <RefenaContainer>[];
  const channel = HttpChannel(host: '127.0.0.1', port: 53317, https: false);
  final device = Device.empty.copyWith(
    alias: 'Fixture receiver',
    version: '2.2',
    fingerprint: 'fixture-device',
    ip: channel.host,
    port: channel.port,
    channels: [channel],
  );
  CrossFile source(String name) => CrossFile(
    name: name,
    size: 3,
    bytes: [1, 2, 3],
    path: null,
    fileType: FileType.other,
    asset: null,
    thumbnail: null,
    lastModified: null,
    lastAccessed: null,
  );
  RefenaContainer container({_Sender? sender, SendRecoveryStore? store}) {
    final result = RefenaContainer(
      overrides: [
        if (sender != null) sendProvider.overrideWithNotifier((_) => sender),
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(device)),
        if (store != null) sendRecoveryStoreProvider.overrideWithValue(store),
      ],
    );
    containers.add(result);
    return result;
  }

  Future<void> close(RefenaContainer container) async {
    final queue = container.notifier(sendQueueProvider);
    container.disposeContainer();
    await queue.recoveryClosed;
    containers.remove(container);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legnasend-recovery-init-');
  });
  tearDown(() async {
    for (final container in containers.toList()) {
      await close(container);
    }
    await temp.delete(recursive: true);
  });

  test('native bootstrap uses private application support rather than Downloads or temp cache', () async {
    final ref = container();
    final support = p.join(temp.path, 'Support 用户');
    await initializeSendRecovery(
      ref,
      sourceEndInitializer: (_, _) async {},
      portable: false,
      supportDirectory: () async => support,
      portableSettingsPath: () => throw StateError('Portable location must not be consulted'),
    );
    expect(ref.read(sendRecoveryStoreProvider)!.root.path, p.join(support, '.legnasend-send-recovery'));
    expect(ref.read(workspaceCaptureStoreProvider)!.root.path, p.join(support, '.legnasend-workspace-captures'));
    expect(await ref.read(sendRecoveryStoreProvider)!.root.exists(), true);
    expect(ref.read(sendRecoveryIssueProvider), isNull);
    expect(ref.read(sendQueueProvider), isEmpty);
  });

  test('cleanup journal failure is not misreported as failed send recovery', () async {
    final ref = container();
    await initializeSendRecovery(
      ref,
      portable: false,
      supportDirectory: () async => temp.path,
      sourceEndInitializer: (_, _) async => throw const FileSystemException('private cleanup journal denied'),
    );
    expect(ref.read(sendRecoveryIssueProvider), 'cleanupStorage');
    expect(ref.read(sendQueueProvider), isEmpty);
    final store = ref.read(sendRecoveryStoreProvider)!;
    await store.saveManifest(SendJob(id: 'still-persistent', target: device, files: [source('queued.bin')]));
    expect((await store.load()).single.id, 'still-persistent');
  });

  test('startup diagnostics retain native error category but not private paths or credentials', () async {
    final records = <LogRecord>[];
    final subscription = Logger('SendRecoveryInitialization').onRecord.listen(records.add);
    try {
      final ref = container();
      await initializeSendRecovery(
        ref,
        portable: false,
        supportDirectory: () async => temp.path,
        sourceEndInitializer: (_, _) async => throw StateError(
          'source_end_journal_unavailable(kind=PermissionDenied, errno=1) /private/secret key=private-token',
        ),
      );
      final messages = records.map((record) => record.message).join(' ');
      expect(messages, contains('kind=PermissionDenied, os=1'));
      expect(messages, isNot(contains('/private/secret')));
      expect(messages, isNot(contains('private-token')));
      expect(ref.read(sendRecoveryIssueProvider), 'cleanupStorage');
    } finally {
      await subscription.cancel();
    }
  });

  test('cleanup journal failure preserves an existing send recovery failure', () async {
    final ref = container();
    await File(p.join(temp.path, '.legnasend-send-recovery')).writeAsString('keep');
    await initializeSendRecovery(
      ref,
      portable: false,
      supportDirectory: () async => temp.path,
      sourceEndInitializer: (_, _) async => throw StateError('cleanup unavailable'),
    );
    expect(ref.read(sendRecoveryIssueProvider), 'storage');
    expect(await File(p.join(temp.path, '.legnasend-send-recovery')).readAsString(), 'keep');
  });

  test('portable bootstrap keeps recovery beside portable settings and ignores application support', () async {
    final ref = container();
    final portable = p.join(temp.path, 'Portable 用户', 'settings.json');
    await initializeSendRecovery(
      ref,
      sourceEndInitializer: (_, _) async {},
      portable: true,
      portableSettingsPath: () => portable,
      supportDirectory: () async => throw StateError('Application support must not be consulted'),
    );
    expect(ref.read(sendRecoveryStoreProvider)!.root.path, p.join(p.dirname(portable), '.legnasend-send-recovery'));
    expect(ref.read(workspaceCaptureStoreProvider)!.root.path, p.join(p.dirname(portable), '.legnasend-workspace-captures'));
    expect(await ref.read(sendRecoveryStoreProvider)!.root.exists(), true);
    expect(ref.read(sendRecoveryIssueProvider), isNull);
  });

  for (final portable in [false, true]) {
    test('${portable ? 'portable' : 'support'} path resolution failure is reported without throwing or creating a fallback journal', () async {
      final ref = container();
      await initializeSendRecovery(
        ref,
        sourceEndInitializer: (_, _) async {},
        portable: portable,
        supportDirectory: () async => throw const FileSystemException('No support location'),
        portableSettingsPath: () => throw const FileSystemException('No portable location'),
      );
      expect(ref.read(sendRecoveryStoreProvider), isNull);
      expect(ref.read(sendRecoveryIssueProvider), 'storage');
      expect(ref.read(sendQueueProvider), isEmpty);
      expect(await temp.list().toList(), isEmpty);
    });
  }

  test('a file at the recovery directory reports storage failure without replacing user content', () async {
    final blocked = await File(p.join(temp.path, '.legnasend-send-recovery')).writeAsString('keep user data');
    final ref = container();
    await initializeSendRecovery(ref, sourceEndInitializer: (_, _) async {}, portable: false, supportDirectory: () async => temp.path);
    expect(ref.read(sendRecoveryIssueProvider), 'storage');
    expect(ref.read(sendQueueProvider), isEmpty);
    expect(await blocked.readAsString(), 'keep user data');
  });

  test('bootstrap restores a saved queued manifest without calling the sender even when the peer is visible', () async {
    final root = Directory(p.join(temp.path, '.legnasend-send-recovery'));
    await SendRecoveryStore(
      root,
    ).saveManifest(SendJob(id: 'previously-queued', target: device, selectedChannel: channel, files: [source('queued.bin')]));
    final sender = _Sender();
    final ref = container(sender: sender);
    await initializeSendRecovery(ref, sourceEndInitializer: (_, _) async {}, portable: false, supportDirectory: () async => temp.path);
    final restored = ref.read(sendQueueProvider).single;
    expect(restored.id, 'previously-queued');
    expect(restored.restored, true);
    expect(restored.terminal, true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sender.ids, isEmpty);
  });

  test('unavailable persistent storage still permits an ordinary in-memory send attempt', () async {
    final blocked = await File(p.join(temp.path, 'blocked')).writeAsString('leave me');
    final sender = _Sender();
    final ref = container(sender: sender, store: SendRecoveryStore(Directory(blocked.path)));
    final queue = ref.notifier(sendQueueProvider);
    await queue.initializeRecovery();
    expect(ref.read(sendRecoveryIssueProvider), 'storage');
    final id = queue.enqueueExplicit(device, [source('normal.bin')], channel);
    await _until(() => ref.read(sendQueueProvider).single.terminal);
    expect(sender.ids, [id]);
    expect(ref.read(sendQueueProvider).single.result, SessionStatus.declined);
    expect(await blocked.readAsString(), 'leave me');
  });

  test('a queued same-device send is persisted before its execution slot becomes available', () async {
    final root = Directory(p.join(temp.path, 'journal'));
    final sender = _Sender(held: Completer<void>());
    final ref = container(sender: sender, store: SendRecoveryStore(root));
    final queue = ref.notifier(sendQueueProvider);
    await queue.initializeRecovery();
    final first = queue.enqueueExplicit(device, [source('first.bin')], channel);
    await _until(() => sender.ids.isNotEmpty);
    final waiting = queue.enqueueExplicit(device, [source('waiting.bin')], channel);
    await queue.flushRecovery();
    expect(ref.read(sendQueueProvider).firstWhere((j) => j.id == waiting).status, SendJobStatus.queued);
    expect(sender.ids, [first]);
    final recorded = await SendRecoveryStore(root).load();
    expect(recorded.map((j) => j.id).toSet(), {first, waiting});
    expect(recorded.firstWhere((j) => j.id == waiting).files.single.name, 'waiting.bin');
    // Finish the unit spy before disposing the container; this is metadata/FIFO
    // validation, not a simulation of real network cancellation.
    await queue.cancel(waiting);
    await queue.cancel(first);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await close(ref);
    final nextSender = _Sender();
    final next = container(sender: nextSender, store: SendRecoveryStore(root));
    await next.notifier(sendQueueProvider).initializeRecovery();
    expect(next.read(sendQueueProvider).map((j) => j.id).toSet(), {first, waiting});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(nextSender.ids, isEmpty);
  });
}
