import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../fixtures/transfer_fixtures.dart';

class _Isolates extends Mock implements IsolateController {}

class _Favorites extends Mock implements FavoritesService {}

class _Nearby extends NearbyDevicesService {
  _Nearby() : super(isolateController: _Isolates(), favoriteService: _Favorites(), discoveryLogs: DiscoveryLogger());
  @override
  NearbyDevicesState init() => const NearbyDevicesState(runningFavoriteScan: false, runningIps: {}, devices: {}, signalingDevices: {});
}

class _Queue extends SendQueueNotifier {
  final List<SendJob> jobs;
  _Queue(this.jobs);
  @override
  List<SendJob> init() => jobs;
}

class _Sender extends SendNotifier {
  final entered = Completer<void>(), gate = Completer<void>();
  int cancels = 0;
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
    if (!entered.isCompleted) entered.complete();
    await gate.future;
  }

  @override
  Future<void> cancelSessionAndWait(String sessionId) async {
    cancels++;
  }

  @override
  void closeSession(String sessionId) {}
}

void main() {
  const uuid = Uuid();
  for (final scenario in ['sharedSource', 'waitingPeer', 'expired']) {
    test('outbox $scenario withholds secret network dispatch', () async {
      final job = uuid.v4(), key = uuid.v4(), attempt = uuid.v4();
      final store = SourceEndStore(read: () async => null, write: (_) async {});
      await store.track(jobId: job, peer: 'peer', resumeKey: key, peerLabel: 'Peer', name: 'x', attemptId: attempt);
      await store.recordGrant(
        peer: 'peer',
        resumeKey: key,
        jobId: job,
        attemptId: attempt,
        grant: SourceEndGrant(
          version: 1,
          grantId: uuid.v4(),
          round: uuid.v4(),
          token: 'A' * 43,
          expiresAtUnixMs: scenario == 'expired' ? 1 : 2000000000000,
        ),
      );
      await store.requestEnd(job);
      final container = RefenaContainer(
        overrides: [
          sourceEndStoreProvider.overrideWithValue(store),
          nearbyDevicesProvider.overrideWithNotifier((_) => _Nearby()),
          sendQueueProvider.overrideWithNotifier(
            (_) => _Queue(
              scenario == 'sharedSource'
                  ? [
                      SendJob(
                        id: uuid.v4(),
                        target: Device.empty.copyWith(fingerprint: 'peer'),
                        files: [queuedFile('x', 1)],
                        resumeKeys: [key],
                      ),
                    ]
                  : [],
            ),
          ),
        ],
      );
      final notifier = container.notifier(sourceEndProvider);
      await notifier.initialize();
      for (var i = 0; i < 30 && store.notices().single['state'] != scenario; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store.notices().single['state'], scenario);
      expect(store.notices().single['attempts'], 0);
      container.disposeContainer();
    });
  }
  for (final fails in [false, true]) {
    test('real queue cancel persists intent before stop, write failure=$fails', () async {
      var block = false;
      final entered = Completer<void>(), release = Completer<void>();
      final store = SourceEndStore(
        read: () async => null,
        write: (_) async {
          if (block) {
            entered.complete();
            await release.future;
            if (fails) throw StateError('disk');
          }
        },
      );
      final sender = _Sender();
      final container = RefenaContainer(
        overrides: [
          sourceEndStoreProvider.overrideWithValue(store),
          nearbyDevicesProvider.overrideWithNotifier((_) => _Nearby()),
          sendProvider.overrideWithNotifier((_) => sender),
        ],
      );
      final queue = container.notifier(sendQueueProvider);
      final peer = Device.empty.copyWith(
        fingerprint: 'peer',
        ip: '127.0.0.1',
        channels: [const HttpChannel(host: '127.0.0.1', port: 53317, https: false)],
      );
      final id = queue.enqueue(peer, [queuedFile('x', 1)]);
      await sender.entered.future;
      final key = container.read(sendQueueProvider).single.resumeKeys.single;
      await store.track(jobId: id, peer: 'peer', resumeKey: key, peerLabel: 'Peer', name: 'x', attemptId: uuid.v4());
      block = true;
      final cancel = queue.cancel(id);
      final failure = fails ? expectLater(cancel, throwsA(isA<SourceEndStorageException>())) : null;
      await entered.future;
      expect(sender.cancels, 0);
      expect(container.read(sendQueueProvider).single.status, SendJobStatus.running);
      release.complete();
      if (failure != null) {
        await failure;
        expect(sender.cancels, 0);
      } else {
        await cancel;
        expect(sender.cancels, 1);
        expect(store.ended('peer', key), true);
      }
      sender.gate.complete();
      await Future<void>.delayed(Duration.zero);
      if (!fails) {
        queue.retry(container.read(sendQueueProvider).single);
        expect(container.read(sendQueueProvider).last.resumeKeys.single, isNot(key));
      }
      container.disposeContainer();
      await queue.recoveryClosed;
    });
  }
  test('configured but unreadable journal blocks cancellation rather than silently disabling authority', () async {
    final container = RefenaContainer(overrides: [sourceEndRequiredProvider.overrideWithValue(true)]);
    await expectLater(container.notifier(sourceEndProvider).endJob(uuid.v4()), throwsA(isA<SourceEndStorageException>()));
    container.disposeContainer();
  });
}
