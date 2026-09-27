import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _Isolates extends Mock implements IsolateController {}

class _Favorites extends Mock implements FavoritesService {}

class _Nearby extends NearbyDevicesService {
  final Device device;
  _Nearby(this.device) : super(isolateController: _Isolates(), favoriteService: _Favorites(), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {device.fingerprint: device}, signalingDevices: {});
}

/// Network boundary is counted, not emulated as a successful wire transfer.
class _NetworkBoundary extends SendNotifier {
  int starts = 0;
  final routes = <LocalSendRoute?>[];
  Completer<void>? networkGate;
  @override
  Map<String, SendSessionState> init() => {};
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
    starts++;
    routes.add(localRoute);
    await networkGate?.future;
  }

  @override
  Future<void> cancelSessionAndWait(String sessionId) async {}
  @override
  void closeSession(String sessionId) {}
  @override
  Future<void> releaseRemoteSession(String sessionId) async {}
}

class _Settings extends Mock implements SettingsService {}

class _RouteNetwork extends LocalIpService {
  _RouteNetwork() : super(_Settings(), monitor: false);
  @override
  NetworkState init() => const NetworkState(
    localIps: [],
    initialized: true,
    addresses: [
      LocalNetworkAddress(interfaceName: 'en7', address: '192.168.7.10'),
    ],
  );
}

class _LoseRoute extends ReduxAction<LocalIpService, NetworkState> {
  @override
  NetworkState reduce() => const NetworkState(localIps: [], initialized: true);
}

class _GatedStore extends SendRecoveryStore {
  _GatedStore(super.root);
  int validations = 0;
  Completer<void>? validationGate;
  final validationStarted = Completer<void>();
  final validationFinished = Completer<void>();
  Completer<void>? captureGate;
  final captureStarted = Completer<void>();
  Completer<void>? ownedSavedGate;
  final ownedSaved = Completer<void>();
  String? ownedJobId;
  @override
  Future<SendJob> saveManifest(SendJob job, {bool copyLocalSources = false}) async {
    if (captureGate != null) {
      if (!captureStarted.isCompleted) captureStarted.complete();
      await captureGate!.future;
    }
    if (copyLocalSources) ownedJobId = job.id;
    final saved = await super.saveManifest(job, copyLocalSources: copyLocalSources);
    if (copyLocalSources && ownedSavedGate != null) {
      if (!ownedSaved.isCompleted) ownedSaved.complete();
      await ownedSavedGate!.future;
    }
    return saved;
  }

  Completer<void>? loadGate;
  final loadStarted = Completer<void>();
  @override
  Future<void> validateRemaining(SendJob job) async {
    final call = ++validations;
    try {
      if (call == 2 && validationGate != null) {
        validationStarted.complete();
        await validationGate!.future;
      }
      await super.validateRemaining(job);
    } finally {
      if (call == 2) validationFinished.complete();
    }
  }

  @override
  Future<List<SendJob>> load() async {
    if (!loadStarted.isCompleted) loadStarted.complete();
    await loadGate?.future;
    return super.load();
  }
}

void main() {
  late Directory temp;
  late _GatedStore store;
  const channel = HttpChannel(host: '127.0.0.1', port: 53317, https: false);
  final peer = Device.empty.copyWith(
    alias: 'Receiver',
    fingerprint: 'identity',
    version: '2.2',
    ip: channel.host,
    port: channel.port,
    channels: [channel],
  );
  const file = CrossFile(
    name: 'message.txt',
    fileType: FileType.text,
    size: 1,
    bytes: [65],
    path: null,
    thumbnail: null,
    asset: null,
    lastModified: null,
    lastAccessed: null,
  );
  RefenaContainer container(_NetworkBoundary sender) => RefenaContainer(
    overrides: [
      sendRecoveryStoreProvider.overrideWithValue(store),
      localIpProvider.overrideWithNotifier((_) => _RouteNetwork()),
      sendProvider.overrideWithNotifier((_) => sender),
      nearbyDevicesProvider.overrideWithNotifier((_) => _Nearby(peer)),
    ],
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recovery-race-');
    store = _GatedStore(Directory('${temp.path}/journal'));
  });
  tearDown(() async {
    await store.releaseSession();
    await temp.delete(recursive: true);
  });

  test('workspace/API owned enqueue does not inherit the UI local route', () async {
    final sender = _NetworkBoundary();
    final c = container(sender);
    final queue = c.notifier(sendQueueProvider);
    c.notifier(sendLocalRouteProvider).select(peer, const LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10'));
    try {
      final id = await queue.enqueueOwned(peer, [file], channel);
      expect(c.read(sendQueueProvider).singleWhere((job) => job.id == id).localRoute, isNull);
      await Future<void>.delayed(Duration.zero);
      expect((await store.load()).single.localRoute, isNull);
      expect(sender.routes, [null]);
    } finally {
      c.disposeContainer();
      await queue.recoveryClosed;
    }
  });

  for (final loseDuringValidation in [false, true]) {
    test('recovered source route loss blocks network (during source validation=$loseDuringValidation)', () async {
      const route = LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10');
      await store.saveManifest(SendJob(id: 'route-restore', target: peer, files: [file], selectedChannel: channel, localRoute: route));
      final c = container(_NetworkBoundary());
      // Use the actual installed override for the network boundary count.
      final network = c.notifier(sendProvider) as _NetworkBoundary;
      final queue = c.notifier(sendQueueProvider);
      try {
        await queue.initializeRecovery();
        if (loseDuringValidation) {
          store.validationGate = Completer<void>();
          expect(await queue.resumeRecovered(c.read(sendQueueProvider).single), isTrue);
          await store.validationStarted.future;
          c.redux(localIpProvider).dispatch(_LoseRoute());
          store.validationGate!.complete();
          await store.validationFinished.future;
          await Future<void>.delayed(Duration.zero);
        } else {
          c.redux(localIpProvider).dispatch(_LoseRoute());
          expect(await queue.resumeRecovered(c.read(sendQueueProvider).single), isFalse);
        }
        expect(network.starts, 0);
        expect(c.read(sendQueueProvider).single.localRoute, route);
        expect(c.read(sendQueueProvider).single.recoveryIssue, 'selectedLocalRouteUnavailable');
        expect(c.read(sendQueueProvider).single.status, SendJobStatus.failed);
      } finally {
        c.disposeContainer();
        await queue.recoveryClosed;
      }
    });
  }

  test('owned enqueue rolls back complete copies when its owner changes before admission', () async {
    store.ownedSavedGate = Completer<void>();
    final c = container(_NetworkBoundary());
    final queue = c.notifier(sendQueueProvider);
    var current = true;
    try {
      final pending = queue.enqueueOwned(peer, [file], channel, isCurrent: () => current);
      final rejected = expectLater(pending, throwsStateError);
      await store.ownedSaved.future;
      expect(await store.load(), hasLength(1));
      current = false;
      store.ownedSavedGate!.complete();
      await rejected;
      expect(c.read(sendQueueProvider), isEmpty);
      expect(await store.load(), isEmpty);
      expect((await store.root.list().toList()).whereType<Directory>(), isEmpty);
    } finally {
      c.disposeContainer();
      await queue.recoveryClosed;
    }
  });

  test('owned enqueue removes partial copies when source capture fails', () async {
    final c = container(_NetworkBoundary());
    final queue = c.notifier(sendQueueProvider);
    try {
      await expectLater(
        queue.enqueueOwned(peer, [file, file.copyWith(name: 'bad.txt', size: 2)], channel),
        throwsA(isA<SendRecoveryException>()),
      );
      expect(c.read(sendQueueProvider), isEmpty);
      expect((await store.root.list().toList()).whereType<Directory>(), isEmpty);
      expect(await store.load(), isEmpty);
    } finally {
      c.disposeContainer();
      await queue.recoveryClosed;
    }
  });

  test('owned enqueue rolls back if the local queue fills during source I/O', () async {
    store.ownedSavedGate = Completer<void>();
    final sender = _NetworkBoundary()..networkGate = Completer<void>();
    final c = container(sender);
    final queue = c.notifier(sendQueueProvider);
    try {
      final pending = queue.enqueueOwned(peer, [file], channel);
      final rejected = expectLater(pending, throwsStateError);
      await store.ownedSaved.future;
      for (var i = 0; i < 128; i++) {
        queue.enqueueExplicit(peer, [file], channel);
      }
      store.ownedSavedGate!.complete();
      await rejected;
      expect(c.read(sendQueueProvider), hasLength(128));
      expect(c.read(sendQueueProvider).any((job) => job.id == store.ownedJobId), isFalse);
      expect((await store.load()).any((job) => job.id == store.ownedJobId), isFalse);
    } finally {
      sender.networkGate!.complete();
      c.disposeContainer();
      await queue.recoveryClosed;
    }
  });

  test('dispose waits for owned capture rollback before releasing its journal lease', () async {
    store.ownedSavedGate = Completer<void>();
    final c = container(_NetworkBoundary());
    final queue = c.notifier(sendQueueProvider);
    final pending = queue.enqueueOwned(peer, [file], channel);
    final rejected = expectLater(pending, throwsStateError);
    await store.ownedSaved.future;
    c.disposeContainer();
    var closed = false;
    final closing = queue.recoveryClosed.then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    final second = SendRecoveryStore(store.root);
    await expectLater(second.claimSession(), throwsA(isA<SendRecoveryException>().having((e) => e.code, 'code', 'busy')));
    store.ownedSavedGate!.complete();
    await rejected;
    await closing;
    await second.claimSession();
    expect(await second.load(), isEmpty);
    await second.releaseSession();
  });

  for (final failure in [false, true]) {
    test('cancel during second source validation never starts network (validation failure: $failure)', () async {
      await store.saveManifest(SendJob(id: 'restore', target: peer, files: [file]));
      store.validationGate = Completer<void>();
      final sender = _NetworkBoundary();
      final c = container(sender);
      final queue = c.notifier(sendQueueProvider);
      try {
        await queue.initializeRecovery();
        expect(await queue.resumeRecovered(c.read(sendQueueProvider).single), isTrue);
        await store.validationStarted.future.timeout(const Duration(seconds: 5));
        await queue.cancel('restore');
        if (failure) {
          store.validationGate!.completeError(const SendRecoveryException('sourceChanged'));
        } else {
          store.validationGate!.complete();
        }
        await store.validationFinished.future.timeout(const Duration(seconds: 15));
        // The disk transaction has actually finished. Drain the continuation
        // and cancellation microtasks before testing removal of the device slot.
        await Future<void>.delayed(Duration.zero);
        expect(c.read(sendQueueProvider).single.status, SendJobStatus.canceled);
        expect(sender.starts, 0);
        await queue.removeAndWait('restore');
        expect(c.read(sendQueueProvider), isEmpty);
      } finally {
        c.disposeContainer();
        await queue.recoveryClosed;
      }
    });
  }

  test('dispose waits for initialization before reporting journal ownership released', () async {
    store.loadGate = Completer<void>();
    final c = container(_NetworkBoundary());
    final queue = c.notifier(sendQueueProvider);
    final initialization = queue.initializeRecovery();
    await store.loadStarted.future;
    c.disposeContainer();
    var closed = false;
    final closing = queue.recoveryClosed.then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    final second = SendRecoveryStore(store.root);
    await expectLater(second.claimSession(), throwsA(isA<SendRecoveryException>().having((e) => e.code, 'code', 'busy')));
    store.loadGate!.complete();
    await initialization;
    await closing;
    await second.claimSession();
    await second.releaseSession();
  });

  test('more than 128 persisted terminal records restore without truncation or automatic network', () async {
    final path = await File('${temp.path}/source').writeAsBytes([1]);
    for (var i = 0; i < 130; i++) {
      await store.saveManifest(
        SendJob(
          id: 'history-$i',
          target: peer,
          files: [file.copyWith(bytes: null, path: path.path)],
        ),
      );
    }
    final sender = _NetworkBoundary();
    final c = container(sender);
    final queue = c.notifier(sendQueueProvider);
    try {
      await queue.initializeRecovery();
      expect(c.read(sendQueueProvider), hasLength(130));
      expect(c.read(sendQueueProvider).every((job) => job.restored && job.terminal), isTrue);
      expect(sender.starts, 0);
      expect(store.issues, isEmpty);
    } finally {
      c.disposeContainer();
      await queue.recoveryClosed;
    }
  });
  test(
    'canonical path aliases retain owned sources while a queued retry still references them',
    () async {
      final real = await Directory('${temp.path}/real').create();
      await Link('${temp.path}/alias').create(real.path);
      store = _GatedStore(Directory('${temp.path}/alias/journal'));
      await store.saveManifest(SendJob(id: 'old', target: peer, files: [file]));
      final sender = _NetworkBoundary();
      final c = container(sender);
      final queue = c.notifier(sendQueueProvider);
      try {
        await queue.initializeRecovery();
        final old = c.read(sendQueueProvider).single;
        expect(old.files.single.path, startsWith(await real.resolveSymbolicLinks()));
        store.captureGate = Completer<void>();
        final retry = queue.enqueueExplicit(peer, old.files, channel);
        await store.captureStarted.future.timeout(const Duration(seconds: 5));
        await queue.removeAndWait('old');
        expect(c.read(sendQueueProvider).any((job) => job.id == 'old'), isTrue);
        expect(c.read(sendRecoveryIssueProvider), 'busy');
        expect(await File(old.files.single.path!).exists(), isTrue);
        store.captureGate!.complete();
        for (var i = 0; i < 200; i++) {
          final current = c.read(sendQueueProvider).firstWhere((job) => job.id == retry);
          if (current.terminal && current.files.single.path != old.files.single.path) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final current = c.read(sendQueueProvider).firstWhere((job) => job.id == retry);
        expect(current.files.single.path, isNot(old.files.single.path));
        await queue.removeAndWait('old');
        expect(c.read(sendQueueProvider).any((job) => job.id == 'old'), isFalse);
        expect(await File(current.files.single.path!).readAsBytes(), [65]);
      } finally {
        if (store.captureGate != null && !store.captureGate!.isCompleted) store.captureGate!.complete();
        c.disposeContainer();
        await queue.recoveryClosed;
      }
    },
    skip: Platform.isWindows ? 'The path-alias fixture requires symbolic-link creation privileges on Windows.' : false,
  );
}
