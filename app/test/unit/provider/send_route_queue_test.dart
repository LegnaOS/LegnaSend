import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

class _Isolates extends Mock implements IsolateController {}

class _Discovery extends NearbyDevicesService {
  final Device device;
  _Discovery(this.device)
    : super(isolateController: _Isolates(), favoriteService: FavoritesService(MockPersistenceService()), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() =>
      NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {device.fingerprint: device}, signalingDevices: {});
}

class _Sender extends SendNotifier {
  final targets = <Device>[];
  final routes = <LocalSendRoute?>[];
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
    targets.add(target);
    routes.add(localRoute);
    state = {
      ...state,
      requestedSessionId!: outgoing(requestedSessionId, status: SessionStatus.declined).copyWith(target: target, localRoute: localRoute),
    };
  }

  void failedSession(String id, Device target, LocalSendRoute route) {
    state = {...state, id: outgoing(id, status: SessionStatus.finishedWithErrors).copyWith(target: target, localRoute: route)};
    ref.notifier(fileTransferProvider).setStatuses(sessionId: id, statuses: {'out': FileStatus.failed});
  }

  @override
  Future<void> releaseRemoteSession(String sessionId) async {}
}

class _Network extends LocalIpService {
  _Network() : super(SettingsService(MockPersistenceService()), monitor: false);
  @override
  NetworkState init() => const NetworkState(
    localIps: [],
    initialized: true,
    addresses: [
      LocalNetworkAddress(interfaceName: 'en7', address: '192.168.7.10'),
      LocalNetworkAddress(interfaceName: 'en8', address: '192.168.8.10'),
    ],
  );
}

class _ReplaceNetwork extends ReduxAction<LocalIpService, NetworkState> {
  final List<LocalNetworkAddress> addresses;
  _ReplaceNetwork(this.addresses);
  @override
  NetworkState reduce() => NetworkState(localIps: [], initialized: true, addresses: addresses);
}

class _PartialSender extends SendNotifier {
  final calls = <List<CrossFile>>[];
  final pending = Completer<void>();
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
    calls.add(files);
    final id = requestedSessionId!;
    state = {
      ...state,
      id: outgoing(id).copyWith(
        target: target,
        files: {
          for (var i = 0; i < files.length; i++)
            '$i': SendingFile(
              file: FileDto(
                id: '$i',
                fileName: files[i].name,
                size: files[i].size,
                fileType: files[i].fileType,
                hash: null,
                preview: null,
                metadata: null,
              ),
              token: '$i',
              thumbnail: null,
              asset: null,
              path: files[i].path,
              bytes: files[i].bytes,
              errorMessage: null,
            ),
        },
      ),
    };
    if (calls.length == 1) {
      ref
          .notifier(fileTransferProvider)
          .setStatuses(
            sessionId: id,
            statuses: {
              '0': FileStatus.finished,
              '1': FileStatus.skipped,
              '2': FileStatus.sending,
            },
          );
      await pending.future;
    } else {
      state = {...state, id: state[id]!.copyWith(status: SessionStatus.finished)};
    }
  }

  @override
  Future<void> cancelSessionAndWait(String sessionId) async {
    state = {...state}..remove(sessionId);
    ref.notifier(fileTransferProvider).removeSession(sessionId);
    if (!pending.isCompleted) pending.complete();
  }

  @override
  Future<void> releaseRemoteSession(String sessionId) async {}
}

void main() {
  test('local source is snapshotted for new jobs and retry; explicit API enqueue remains automatic', () async {
    const route = LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10');
    const other = LocalSendRoute(interfaceName: 'en8', localAddress: '192.168.8.10');
    final target = Device.empty.copyWith(ip: '192.168.7.11', port: 53317, fingerprint: 'routed');
    final sender = _Sender();
    final container = RefenaContainer(
      overrides: [
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(target)),
        sendProvider.overrideWithNotifier((_) => sender),
        localIpProvider.overrideWithNotifier((_) => _Network()),
      ],
    );
    addTearDown(container.disposeContainer);
    final routes = container.notifier(sendLocalRouteProvider), queue = container.notifier(sendQueueProvider);
    routes.select(target, route);
    queue.enqueue(target, [queuedFile('first', 1)]);
    routes.select(target, other);
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes, [route]);
    final failed = container.read(sendQueueProvider).single;
    queue.retry(failed);
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes.last, route);
    queue.enqueue(target, [queuedFile('new', 1)]);
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes.last, other);
    queue.enqueueExplicit(target, [queuedFile('api', 1)], HttpChannel(host: target.ip!, port: target.port, https: target.https));
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes.last, isNull);
    expect(container.read(sendQueueProvider).last.localRoute, isNull);
  });

  for (final queued in [false, true]) {
    test('single-file retry inherits ${queued ? 'job' : 'standalone session'} source route despite new UI choice', () async {
      const route = LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10');
      const other = LocalSendRoute(interfaceName: 'en8', localAddress: '192.168.8.10');
      final target = Device.empty.copyWith(ip: '192.168.7.11', port: 53317, fingerprint: 'file-retry');
      final sender = _Sender();
      final container = RefenaContainer(
        overrides: [
          nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(target)),
          sendProvider.overrideWithNotifier((_) => sender),
          localIpProvider.overrideWithNotifier((_) => _Network()),
        ],
      );
      addTearDown(container.disposeContainer);
      final queue = container.notifier(sendQueueProvider);
      container.notifier(sendLocalRouteProvider).select(target, route);
      final id = queued ? queue.enqueue(target, [queuedFile('first', 1)]) : 'direct-session';
      await Future<void>.delayed(Duration.zero);
      sender.failedSession(id, target, route);
      container.notifier(sendLocalRouteProvider).select(target, other);
      final file = container.read(sendProvider)[id]!.files['out']!;
      final retried = queue.retryFile(sessionId: id, file: file);
      expect(retried, isNotNull);
      await Future<void>.delayed(Duration.zero);
      expect(sender.routes.last, route);
      expect(container.read(sendQueueProvider).singleWhere((job) => job.id == retried).localRoute, route);
    });
  }

  test('lost exact interface/address fails before sending and retry never falls back to automatic', () async {
    const route = LocalSendRoute(interfaceName: 'en7', localAddress: '192.168.7.10');
    final target = Device.empty.copyWith(ip: '192.168.7.11', port: 53317, fingerprint: 'gone');
    final sender = _Sender();
    final container = RefenaContainer(
      overrides: [
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(target)),
        sendProvider.overrideWithNotifier((_) => sender),
        localIpProvider.overrideWithNotifier((_) => _Network()),
      ],
    );
    addTearDown(container.disposeContainer);
    final queue = container.notifier(sendQueueProvider);
    container.notifier(sendLocalRouteProvider).select(target, route);
    queue.enqueue(target, [queuedFile('first', 1)]);
    container.redux(localIpProvider).dispatch(_ReplaceNetwork([const LocalNetworkAddress(interfaceName: 'en8', address: '192.168.7.10')]));
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes, isEmpty);
    final failed = container.read(sendQueueProvider).single;
    expect(failed.status, SendJobStatus.failed);
    expect(failed.error, contains('selected-local-route-unavailable'));
    container.notifier(sendLocalRouteProvider).select(target, null);
    queue.retry(failed);
    await Future<void>.delayed(Duration.zero);
    expect(sender.routes, isEmpty);
    expect(container.read(sendQueueProvider).last.localRoute, route);
  });

  test('actual queue provider snapshots drag/click entry point and retries independently of UI choice', () async {
    const local = HttpChannel(host: '192.168.1.9', port: 53317, https: false);
    const tunnel = HttpChannel(host: '10.8.0.9', port: 53318, https: true);
    final original = Device.empty.copyWith(fingerprint: 'peer', ip: local.host, port: local.port, channels: [local, tunnel]);
    final discovered = original.copyWith(ip: tunnel.host, port: tunnel.port, https: true, channels: [tunnel, local]);
    final sender = _Sender();
    final container = RefenaContainer(
      overrides: [
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(discovered)),
        sendProvider.overrideWithNotifier((_) => sender),
      ],
    );
    addTearDown(() => container.dispose(sendQueueProvider));
    final routes = container.notifier(sendRouteProvider);
    final queue = container.notifier(sendQueueProvider);
    routes.select(original, local);
    queue.enqueue(original, [queuedFile('a', 1)]);
    await Future<void>.delayed(Duration.zero);
    expect(sender.targets.single.ip, local.host);
    expect(sender.targets.single.https, isFalse);
    final failed = container.read(sendQueueProvider).single;
    expect(failed.selectedChannel, local);
    routes.select(original, tunnel);
    queue.retry(failed);
    await Future<void>.delayed(Duration.zero);
    expect(sender.targets.last.ip, local.host);
    expect(sender.targets.last.port, local.port);
    routes.select(original, null);
    queue.enqueue(original, [queuedFile('b', 1)]);
    await Future<void>.delayed(Duration.zero);
    expect(sender.targets.last.ip, tunnel.host);
    expect(sender.targets.last.https, isTrue);
    expect(container.read(sendQueueProvider).last.selectedChannel, isNull);
  });
  test('cancel closes live session but queue retry retains completed and declined file outcomes', () async {
    final sender = _PartialSender();
    final device = Device.empty.copyWith(ip: '127.0.0.1', port: 53317, fingerprint: 'partial');
    final container = RefenaContainer(
      overrides: [
        nearbyDevicesProvider.overrideWithNotifier((_) => _Discovery(device)),
        sendProvider.overrideWithNotifier((_) => sender),
      ],
    );
    addTearDown(() => container.dispose(sendQueueProvider));
    final queue = container.notifier(sendQueueProvider);
    final id = queue.enqueue(device, [queuedFile('done', 1), queuedFile('declined', 2), queuedFile('pending', 3)]);
    await Future<void>.delayed(Duration.zero);
    await queue.cancel(id);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sendProvider)[id], isNull);
    final canceled = container.read(sendQueueProvider).single;
    queue.retry(canceled);
    await Future<void>.delayed(Duration.zero);
    expect(sender.calls.length, 2);
    expect(sender.calls.last.map((f) => f.name), ['pending.bin']);
    final completed = container.read(sendQueueProvider).last;
    queue.retry(completed);
    expect(container.read(sendQueueProvider).length, 2);
    queue.remove(canceled.id);
    queue.retry(canceled);
    expect(container.read(sendQueueProvider).length, 1);
  });
}
