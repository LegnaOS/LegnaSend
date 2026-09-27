import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../../fixtures/transfer_fixtures.dart';

class _Jobs extends SendQueueNotifier {
  final List<SendJob> initial;
  _Jobs(this.initial);
  @override
  List<SendJob> init() => initial;
}

class _Sends extends SendNotifier {
  final Map<String, SendSessionState> initial;
  _Sends(this.initial);
  @override
  Map<String, SendSessionState> init() => initial;
}

class _Selection extends SelectedSendingFilesNotifier {
  @override
  List<CrossFile> init() => [queuedFile('selected', 4)];
}

void main() {
  test('pure guard retains every source-bearing state including terminal job history', () {
    expect(shouldPreserveSendingCaches(hasSelection: false, hasQueueJobs: false, hasSendSessions: false), false);
    for (var mask = 1; mask < 8; mask++) {
      expect(shouldPreserveSendingCaches(hasSelection: mask & 1 != 0, hasQueueJobs: mask & 2 != 0, hasSendSessions: mask & 4 != 0), true);
    }
  });

  for (final status in SendJobStatus.values) {
    test('actual ClearSelectionAction retains ${status.name} queue sources while registered receive cleanup runs', () async {
      var registered = 0;
      var bulk = 0;
      final job = SendJob(id: 'job', target: Device.empty, files: [queuedFile('cached-source', 4)], status: status);
      final container = RefenaContainer(
        overrides: [
          selectedSendingFilesProvider.overrideWithNotifier((_) => _Selection()),
          sendQueueProvider.overrideWithNotifier((_) => _Jobs([job])),
          registeredReceiveCacheCleanupProvider.overrideWithValue(() async {
            registered++;
          }),
          generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
            bulk++;
          }),
        ],
      );
      addTearDown(container.disposeContainer);
      container.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(selectedSendingFilesProvider), isEmpty);
      expect(registered, 1);
      expect(bulk, 0);
    });
  }

  test('actual ClearSelectionAction cleans general caches when no source references remain', () async {
    var registered = 0;
    var bulk = 0;
    final container = RefenaContainer(
      overrides: [
        selectedSendingFilesProvider.overrideWithNotifier((_) => _Selection()),
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {
          registered++;
        }),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
          bulk++;
        }),
      ],
    );
    addTearDown(container.disposeContainer);
    container.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    await Future<void>.delayed(Duration.zero);
    expect(registered, 1);
    expect(bulk, 1);
  });

  test('native retained send sessions protect sources independently of the queue', () async {
    var bulk = 0;
    final container = RefenaContainer(
      overrides: [
        sendProvider.overrideWithNotifier((_) => _Sends({'native': outgoing('native')})),
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {}),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
          bulk++;
        }),
      ],
    );
    addTearDown(container.disposeContainer);
    await container.global.dispatchAsync(ClearCacheAction());
    expect(bulk, 0);
  });

  test('source guard re-reads selection after registered cleanup await', () async {
    final gate = Completer<void>();
    var bulk = 0;
    final container = RefenaContainer(
      overrides: [
        registeredReceiveCacheCleanupProvider.overrideWithValue(() => gate.future),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {
          bulk++;
        }),
      ],
    );
    addTearDown(container.disposeContainer);
    final clearing = container.global.dispatchAsync(ClearCacheAction());
    await Future<void>.delayed(Duration.zero);
    container.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: 'source'));
    gate.complete();
    await clearing;
    expect(bulk, 0);
  });
}
