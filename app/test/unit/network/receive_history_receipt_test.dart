import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

class _UnusedParent extends Fake implements ParentIsolateState {}

class _Decisions extends RefenaObserver {
  final actions = <IsolateHttpServerPrepareUploadDecisionAction>[];
  @override
  void handleEvent(RefenaEvent event) {
    if (event is ActionDispatchedEvent && event.action is IsolateHttpServerPrepareUploadDecisionAction) {
      actions.add(event.action as IsolateHttpServerPrepareUploadDecisionAction);
    }
  }
}

class _Storage extends MockPersistenceService {
  List<ReceiveHistoryEntry> disk = [];
  final gate = Completer<void>(), entered = Completer<void>();
  bool fail = false;
  @override
  bool isSaveToHistory() => true;
  @override
  List<ReceiveHistoryEntry> getReceiveHistory() => disk;
  @override
  Future<void> setReceiveHistory(List<ReceiveHistoryEntry>? entries, {DateTime? clearedThrough}) async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    if (fail) throw StateError('disk full');
    disk = List.of(entries!);
  }
}

HttpServerFileUploadResultEvent _result(String session, {String? error}) => HttpServerFileUploadResultEvent(
  sessionId: session,
  fileId: 'in',
  path: '/published/old-name.bin',
  savedToGallery: true,
  error: error,
  receipt: HttpServerReceiveReceipt(
    receiptId: 'native:receipt-1',
    fileName: 'old-name.bin',
    fileType: FileType.other,
    fileSize: 100,
    senderAlias: 'Old sender',
    timestamp: DateTime.utc(2026, 9, 25),
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('accept config carries the displayed sender alias into child publication receipts', () async {
    final observer = _Decisions();
    final container = RefenaContainer(
      observers: [observer],
      overrides: [
        deviceInfoProvider.overrideWithBuilder((_) => DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Fixture', androidSdkInt: null)),
        parentIsolateProvider.overrideWithReducer(
          notifier: (_) => IsolateController(initialState: _UnusedParent()),
          reducer: {IsolateHttpServerPrepareUploadDecisionAction: (state) => state},
        ),
      ],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(
      alias: 'Self',
      port: 1,
      https: false,
      session: incoming('old', status: SessionStatus.waiting).copyWith(senderAlias: 'My favorite sender'),
      web: null,
    );
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    await controller.acceptFileRequest({}, expectedSessionId: 'old');
    expect(observer.actions.single.config!.senderAlias, 'My favorite sender');
  });
  test('listener-independent receipt API never accesses session state and dual delivery is idempotent', () async {
    final storage = _Storage()..gate.complete();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    addTearDown(container.disposeContainer);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => throw StateError('No listener'),
        getStateOrNull: () => throw StateError('No listener'),
        setState: (_) => throw StateError('History must never alter UI'),
      ),
    );
    await controller.onReceiveReceipt(_result('old', error: 'failed'));
    expect(storage.disk, isEmpty);
    final event = _result('old');
    await Future.wait([controller.onReceiveReceipt(event), controller.onReceiveReceipt(event)]);
    expect(storage.disk.single.id, 'native:receipt-1');
  });
  for (final current in [true, false]) {
    test('receipt persists with current=$current without blocking terminal UI or touching replacement', () async {
      final storage = _Storage();
      final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
      addTearDown(container.disposeContainer);
      final replacement = incoming('next');
      ServerState? state = ServerState(alias: 'Self', port: 1, https: false, session: current ? incoming('old') : replacement, web: null);
      final controller = ReceiveController(
        ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
      );
      final progress = container.notifier(fileTransferProvider);
      progress.setStatus(sessionId: current ? 'old' : 'next', fileId: 'in', status: FileStatus.sending);
      progress.setProgress(sessionId: 'next', fileId: 'in', progress: 0.42);
      final operation = controller.onFileUploadResult(_result('old'));
      await storage.entered.future;
      if (current) {
        expect(state!.session!.status, SessionStatus.finished);
        expect(state!.session!.files['in']!.path, '/published/old-name.bin');
      } else {
        expect(state!.session, same(replacement));
        expect(progress.getProgress(sessionId: 'next', fileId: 'in'), 0.42);
        expect(progress.getStatus(sessionId: 'next', fileId: 'in'), FileStatus.sending);
      }
      storage.gate.complete();
      await operation;
      await controller.onFileUploadResult(_result('old'));
      expect(storage.disk.length, 1);
      expect(storage.disk.single.id, 'native:receipt-1');
      expect(storage.disk.single.senderAlias, 'Old sender');
      expect(storage.disk.single.fileName, 'old-name.bin');
      expect(storage.disk.single.timestamp, DateTime.utc(2026, 9, 25));
      expect(storage.disk.single.savedToGallery, true);
      if (!current) expect(state!.session, same(replacement));
    });
  }
  test('failed receipt is ignored and failed history write can be replayed exactly once', () async {
    final storage = _Storage()..gate.complete();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    addTearDown(container.disposeContainer);
    ServerState? state = const ServerState(alias: 'Self', port: 1, https: false, session: null, web: null);
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    await controller.onFileUploadResult(_result('old', error: 'failed save'));
    expect(storage.entered.isCompleted, false);
    storage.fail = true;
    await controller.onFileUploadResult(_result('old'));
    expect(container.read(receiveHistoryProvider), isEmpty);
    storage.fail = false;
    await controller.onFileUploadResult(_result('old'));
    expect(storage.disk.length, 1);
    await container.redux(receiveHistoryProvider).dispatchAsync(RemoveAllHistoryEntriesAction());
    await controller.onFileUploadResult(_result('old'));
    expect(storage.disk, isEmpty);
    expect(state!.session, isNull);
  });
}
