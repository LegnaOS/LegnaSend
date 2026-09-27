import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/http.dart' as http;
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/api/server.dart' as rust;
import 'package:refena_flutter/refena_flutter.dart';

import '../../fixtures/transfer_fixtures.dart';
import '../../mocks.mocks.dart';

class _UnusedParent extends Fake implements ParentIsolateState {}

class _FailingHttpClient extends Fake implements http.RsHttpClient {
  int calls = 0;
  @override
  Future<void> cancel({required rust.ProtocolType protocol, required String ip, required int port, required String sessionId}) async {
    calls++;
    throw StateError('peer disconnected');
  }
}

class _HttpClients extends Fake implements HttpClientCollection {
  final _FailingHttpClient client;
  _HttpClients(this.client);
  @override
  http.RsHttpClient pinnedTo(String fingerprint, {LocalSendRoute? localRoute}) => client;
}

class _QuickPersistence extends MockPersistenceService {
  @override
  QuickSaveMode getQuickSave() => QuickSaveMode.on;
}

class _HistoryPersistence extends MockPersistenceService {
  final Future<void> Function() write;
  _HistoryPersistence(this.write);
  @override
  bool isSaveToHistory() => true;
  @override
  List<ReceiveHistoryEntry> getReceiveHistory() => [];
  @override
  Future<void> setReceiveHistory(List<ReceiveHistoryEntry>? entries, {DateTime? clearedThrough}) => write();
}

HttpServerPrepareUploadEvent _prepare(String id) => HttpServerPrepareUploadEvent(
  sessionId: id,
  ip: '127.0.0.1',
  certFingerprint: null,
  files: {},
  info: const rust.RegisterDtoV2(
    alias: 'Fixture',
    version: '2.2',
    fingerprint: 'fixture',
    port: 53317,
    protocol: rust.ProtocolType.http,
    download: false,
  ),
);

HttpServerFileUploadResultEvent _result(String sessionId) => HttpServerFileUploadResultEvent(
  sessionId: sessionId,
  fileId: 'in',
  path: '/destination/in.bin',
  savedToGallery: false,
  error: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('completed receive becomes terminal before slow history persistence finishes', () async {
    final gate = Completer<void>();
    final persistence = _HistoryPersistence(() => gate.future);
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        settingsProvider.overrideWithNotifier((_) => SettingsService(persistence)),
      ],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('old'), web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
    );
    final transfers = container.notifier(fileTransferProvider);
    transfers.setStatus(sessionId: 'old', fileId: 'in', status: FileStatus.sending);
    final operation = controller.onFileUploadResult(_result('old'));
    await Future<void>.delayed(Duration.zero);
    try {
      expect(state!.session!.status, SessionStatus.finished);
      expect(transfers.getProgress(sessionId: 'old', fileId: 'in'), 1);
    } finally {
      gate.complete();
      await operation;
    }
  });
  test('history storage failure does not prevent a successful receive from finishing', () async {
    final persistence = _HistoryPersistence(() async => throw StateError('history storage unavailable'));
    final container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        settingsProvider.overrideWithNotifier((_) => SettingsService(persistence)),
      ],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('receive'), web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
    );
    container.notifier(fileTransferProvider).setStatus(sessionId: 'receive', fileId: 'in', status: FileStatus.sending);
    await expectLater(controller.onFileUploadResult(_result('receive')), completes);
    expect(state!.session!.status, SessionStatus.finished);
    expect(state!.session!.files['in']!.path, '/destination/in.bin');
  });
  test('late terminal and unknown-file progress never mutates receive progress', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    ServerState? state;
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => state!,
        getStateOrNull: () => state,
        setState: (update) => state = update(state),
      ),
    );
    final transfers = container.notifier(fileTransferProvider);
    for (final status in [
      SessionStatus.finished,
      SessionStatus.finishedWithErrors,
      SessionStatus.canceledBySender,
      SessionStatus.canceledByReceiver,
    ]) {
      state = ServerState(
        alias: 'Fixture',
        port: 1,
        https: false,
        session: incoming('same', status: status),
        web: null,
      );
      transfers.setProgress(sessionId: 'same', fileId: 'in', progress: 0.5);
      controller.onFileUploadProgress(HttpServerFileUploadProgressEvent(sessionId: 'same', fileId: 'in', progress: 0.9));
      expect(
        transfers.getProgress(sessionId: 'same', fileId: 'in'),
        0.5,
        reason: status.name,
      );
    }
    state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('same'), web: null);
    controller.onFileUploadProgress(HttpServerFileUploadProgressEvent(sessionId: 'same', fileId: 'unknown', progress: 0.9));
    expect(transfers.getData()['same']!.containsKey('unknown'), false);
  });

  test('listener replacement invalidates pending directory results and failures before another lookup', () async {
    for (final shouldFail in [false, true]) {
      final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
      final destination = Completer<String>();
      ServerState? state = const ServerState(alias: 'Fixture', port: 1, https: false, session: null, web: null);
      var generation = 1, cacheCalls = 0;
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => container,
          getState: () => state!,
          getStateOrNull: () => state,
          getListenerGeneration: () => generation,
          setState: (_) => fail('Old directory callback wrote state'),
        ),
        resolveDefaultDestination: () => destination.future,
        resolveCache: () async {
          cacheCalls++;
          return '/cache';
        },
      );
      final pending = controller.onPrepareUpload(_prepare('old'));
      state = null;
      generation++;
      state = const ServerState(alias: 'Replacement', port: 2, https: false, session: null, web: null);
      if (shouldFail) {
        destination.completeError(StateError('stale directory lookup'));
      } else {
        destination.complete('/destination');
      }
      await pending;
      expect(cacheCalls, 0);
      expect(state.session, isNull);
      container.disposeContainer();
    }
  });

  test('listener replacement invalidates pending cache success and failure without protocol rejection', () async {
    for (final shouldFail in [false, true]) {
      final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
      final cache = Completer<String>();
      final resolvingCache = Completer<void>();
      ServerState? state = const ServerState(alias: 'Fixture', port: 1, https: false, session: null, web: null);
      var generation = 1;
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => container,
          getState: () => state!,
          getStateOrNull: () => state,
          getListenerGeneration: () => generation,
          setState: (_) => fail('Old cache callback wrote state'),
        ),
        resolveDefaultDestination: () async => '/destination',
        resolveCache: () {
          resolvingCache.complete();
          return cache.future;
        },
      );
      final pending = controller.onPrepareUpload(_prepare('old'));
      await resolvingCache.future;
      generation++;
      state = const ServerState(alias: 'Replacement', port: 2, https: false, session: null, web: null);
      if (shouldFail) {
        cache.completeError(StateError('stale cache lookup'));
      } else {
        cache.complete('/cache');
      }
      await pending;
      expect(state.session, isNull);
      container.disposeContainer();
    }
  });

  test('stop releases only receive progress and leaves concurrent sending intact', () {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('receive'), web: null);
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    final transfers = container.notifier(fileTransferProvider);
    transfers.setStatuses(sessionId: 'receive', statuses: {'in': FileStatus.sending});
    transfers.setStatuses(sessionId: 'send', statuses: {'out': FileStatus.sending});
    transfers.setProgress(sessionId: 'send', fileId: 'out', progress: 0.25);
    controller.onServerStopped();
    controller.onServerStopped();
    expect(state!.session, isNull);
    expect(transfers.getData().containsKey('receive'), false);
    expect(transfers.getProgress(sessionId: 'send', fileId: 'out'), 0.25);
  });

  test('permission result after stop cannot accept a replacement with the same session ID', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
    final gate = Completer<Map<int, int>>();
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'requestPermissions');
      requested.complete();
      return gate.future;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final container = RefenaContainer(
      overrides: [
        deviceInfoProvider.overrideWithBuilder((_) => DeviceInfoResult(deviceType: DeviceType.mobile, deviceModel: 'Fixture', androidSdkInt: 32)),
      ],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(
      alias: 'Fixture',
      port: 1,
      https: false,
      session: incoming('same', status: SessionStatus.waiting),
      web: null,
    );
    var generation = 1;
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => container,
        getState: () => state!,
        getStateOrNull: () => state,
        getListenerGeneration: () => generation,
        setState: (update) => state = update(state),
      ),
    );
    final pending = controller.acceptFileRequest({'in': 'old.bin'}, expectedSessionId: 'same');
    await requested.future;
    generation++;
    controller.onServerStopped();
    final replacement = ServerState(alias: 'Replacement', port: 2, https: false, session: incoming('same'), web: null);
    state = replacement;
    gate.complete({15: 1});
    await pending;
    expect(state, same(replacement));
    expect(container.notifier(fileTransferProvider).getData().containsKey('same'), false);
    // A stale decision would access the deliberately uninitialized parent provider.
  });

  test('late successful history completion never updates a replacement session', () async {
    final gate = Completer<void>();
    final persistence = _HistoryPersistence(() => gate.future);
    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistence), settingsProvider.overrideWithNotifier((_) => SettingsService(persistence))],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('same'), web: null);
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    final transfers = container.notifier(fileTransferProvider);
    transfers.setStatus(sessionId: 'same', fileId: 'in', status: FileStatus.sending);
    final pending = controller.onFileUploadResult(_result('same'));
    await Future<void>.delayed(Duration.zero);
    controller.closeSession(expectedSessionId: 'same');
    final replacement = ServerState(alias: 'Replacement', port: 2, https: false, session: incoming('same'), web: null);
    state = replacement;
    transfers.setStatus(sessionId: 'same', fileId: 'in', status: FileStatus.sending);
    transfers.setProgress(sessionId: 'same', fileId: 'in', progress: 0.25);
    gate.complete();
    await pending;
    expect(state, same(replacement));
    expect(transfers.getProgress(sessionId: 'same', fileId: 'in'), 0.25);
    expect(transfers.getStatus(sessionId: 'same', fileId: 'in'), FileStatus.sending);
  });

  test('duplicate terminal callbacks are ignored but an explicit retry can complete', () async {
    var historyWrites = 0;
    final persistence = _HistoryPersistence(() async {
      historyWrites++;
    });
    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistence), settingsProvider.overrideWithNotifier((_) => SettingsService(persistence))],
    );
    addTearDown(container.disposeContainer);
    final first = incoming('session');
    ServerState? state = ServerState(
      alias: 'Fixture',
      port: 1,
      https: false,
      session: first.copyWith(
        files: {
          ...first.files,
          'other': first.files['in']!.copyWith(file: transferFile('other', 100), desiredName: 'other.bin'),
        },
      ),
      web: null,
    );
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    final transfers = container.notifier(fileTransferProvider);
    transfers.setStatuses(sessionId: 'session', statuses: {'in': FileStatus.sending, 'other': FileStatus.sending});
    await controller.onFileUploadResult(_result('session'));
    await controller.onFileUploadResult(_result('session'));
    expect(historyWrites, 1);
    expect(state!.session!.status, SessionStatus.sending);
    HttpServerFileUploadResultEvent failed(String error) =>
        HttpServerFileUploadResultEvent(sessionId: 'session', fileId: 'other', path: null, savedToGallery: false, error: error);
    await controller.onFileUploadResult(failed('original failure'));
    final failedState = state;
    await controller.onFileUploadResult(failed('duplicate failure'));
    expect(state, same(failedState));
    expect(state!.session!.files['other']!.errorMessage, 'original failure');
    controller.onFileUpload(
      HttpServerFileUploadEvent(
        sessionId: 'session',
        fileId: 'other',
        file: rust.FileDto(id: 'other', fileName: 'other.bin', size: BigInt.from(100), fileType: 'application/octet-stream'),
      ),
    );
    expect(state!.session!.status, SessionStatus.sending);
    await controller.onFileUploadResult(
      HttpServerFileUploadResultEvent(sessionId: 'session', fileId: 'other', path: '/destination/other.bin', savedToGallery: false, error: null),
    );
    expect(historyWrites, 2);
    expect(state!.session!.status, SessionStatus.finished);
  });

  test('cancel request failure stays local and cannot close the replacement receive', () async {
    final client = _FailingHttpClient();
    final container = RefenaContainer(
      overrides: [
        httpProvider.overrideWithBuilder((_) => _HttpClients(client)),
        parentIsolateProvider.overrideWithReducer(
          notifier: (_) => IsolateController(initialState: _UnusedParent()),
          reducer: {IsolateHttpServerCancelSessionAction: (state) => state},
        ),
      ],
    );
    addTearDown(container.disposeContainer);
    final session = incoming('old');
    ServerState? state = ServerState(
      alias: 'Fixture',
      port: 1,
      https: false,
      session: session.copyWith(sender: session.sender.copyWith(ip: '127.0.0.1')),
      web: null,
    );
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    final errors = <Object>[];
    final replacement = ServerState(alias: 'Replacement', port: 2, https: false, session: incoming('new'), web: null);
    await runZonedGuarded(() async {
      controller.cancelSession(expectedSessionId: 'old');
      state = replacement;
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));
    expect(client.calls, 1);
    expect(errors, isEmpty);
    expect(state, same(replacement));
  });

  test('late desktop window queries cannot foreground or prompt a stopped receive', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('window_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final query in ['isMinimized', 'isVisible', 'isFocused']) {
      final gate = Completer<bool>(), asked = Completer<void>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        methods.add(call.method);
        if (call.method == query) {
          asked.complete();
          return gate.future;
        }
        return Future.value(call.method != 'isMinimized');
      });
      final persistence = MockPersistenceService();
      final container = RefenaContainer(
        overrides: [persistenceProvider.overrideWithValue(persistence), settingsProvider.overrideWithNotifier((_) => SettingsService(persistence))],
      );
      ServerState? state = const ServerState(alias: 'Fixture', port: 1, https: false, session: null, web: null);
      var generation = 1;
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => container,
          getState: () => state!,
          getStateOrNull: () => state,
          getListenerGeneration: () => generation,
          setState: (update) => state = update(state),
        ),
        resolveDefaultDestination: () async => '/destination',
        resolveCache: () async => '/cache',
      );
      final event = _prepare('old');
      final pending = controller.onPrepareUpload(
        HttpServerPrepareUploadEvent(
          sessionId: event.sessionId,
          ip: event.ip,
          info: event.info,
          certFingerprint: null,
          files: {
            'in': rust.FileDto(id: 'in', fileName: 'in.bin', size: BigInt.from(100), fileType: 'application/octet-stream'),
          },
        ),
      );
      await asked.future;
      generation++;
      controller.onServerStopped();
      state = const ServerState(alias: 'Replacement', port: 2, https: false, session: null, web: null);
      gate.complete(query == 'isMinimized');
      await pending;
      expect(methods.last, query);
      expect(methods, isNot(contains('show')));
      expect(state!.session, isNull);
      container.disposeContainer();
    }
  });

  test('deferred quick-save close never hides a later cancellation of the same session', () async {
    final persistence = _QuickPersistence();
    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistence), settingsProvider.overrideWithNotifier((_) => SettingsService(persistence))],
    );
    addTearDown(container.disposeContainer);
    ServerState? state = ServerState(alias: 'Fixture', port: 1, https: false, session: incoming('receive'), web: null);
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (update) => state = update(state)),
    );
    container.notifier(fileTransferProvider).setStatus(sessionId: 'receive', fileId: 'in', status: FileStatus.sending);
    await controller.onFileUploadResult(_result('receive'));
    controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'receive', reason: rust.SessionEndReasonV2.cancelled));
    await Future<void>.delayed(Duration.zero);
    expect(state!.session?.status, SessionStatus.canceledBySender);
  });
}
