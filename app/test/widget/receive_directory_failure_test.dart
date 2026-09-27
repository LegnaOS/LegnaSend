import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/api/server.dart' as rust;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

import '../mocks.mocks.dart';

class _UnusedParentState extends Fake implements ParentIsolateState {}

class _DestinationPersistence extends MockPersistenceService {
  final String? destination;
  _DestinationPersistence(this.destination);
  @override
  String? getDestination() => destination;
}

class _Decisions extends RefenaObserver {
  final decisions = <IsolateHttpServerPrepareUploadDecisionAction>[];
  @override
  void handleEvent(RefenaEvent event) {
    if (event is ActionDispatchedEvent && event.action is IsolateHttpServerPrepareUploadDecisionAction) {
      decisions.add(event.action as IsolateHttpServerPrepareUploadDecisionAction);
    }
  }
}

HttpServerPrepareUploadEvent _event(String id) => HttpServerPrepareUploadEvent(
  sessionId: id,
  ip: '127.0.0.1',
  info: const rust.RegisterDtoV2(
    alias: 'Fixture',
    version: '2.2',
    fingerprint: 'fixture',
    port: 53317,
    protocol: rust.ProtocolType.http,
    download: false,
  ),
  certFingerprint: null,
  files: {},
);

void main() {
  for (final (failCache, selected) in [
    (false, null),
    (true, null),
    (true, 'content://provider/tree/primary%3ADownload'),
    (true, r'D:\资料\Downloads'),
  ]) {
    testWidgets('directory lookup error rejects exactly the pending request (cache=$failCache, selected=$selected)', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final observer = _Decisions();
      final parentState = _UnusedParentState();
      final container = RefenaContainer(
        observers: [observer],
        overrides: [
          settingsProvider.overrideWithNotifier((_) => SettingsService(_DestinationPersistence(selected))),
          parentIsolateProvider.overrideWithReducer(
            notifier: (_) => IsolateController(initialState: parentState),
            reducer: {IsolateHttpServerPrepareUploadDecisionAction: (state) => state},
          ),
        ],
      );
      addTearDown(container.disposeContainer);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(navigatorKey: Routerino.navigatorKey, home: const Scaffold()),
        ),
      );
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => container,
          getState: () => const ServerState(alias: 'Fixture', port: 53317, https: false, session: null, web: null),
          getStateOrNull: () => const ServerState(alias: 'Fixture', port: 53317, https: false, session: null, web: null),
          setState: (_) => fail('No receive session should be created on lookup failure'),
        ),
        resolveDefaultDestination: () async {
          expect(selected, isNull, reason: 'A user-selected directory or URI must bypass default resolution');
          if (!failCache) throw const FileSystemException('private path must not leak');
          return '/fixture/Downloads';
        },
        resolveCache: () async => throw const FileSystemException('cache unavailable'),
      );
      for (final id in ['first', 'next']) {
        await controller.onPrepareUpload(_event(id));
        await tester.pumpAndSettle();
        expect(observer.decisions.last.sessionId, id);
        expect(observer.decisions.last.config, isNull);
        expect(find.byType(ErrorDialog), findsOneWidget);
        expect(find.text(t.receivePage.destinationUnavailable), findsOneWidget);
        expect(find.textContaining('private path'), findsNothing);
        await tester.tap(find.text(t.general.close));
        await tester.pumpAndSettle();
      }
      expect(observer.decisions, hasLength(2));
      expect(container.read(settingsProvider).destination, selected);
      await tester.pumpWidget(const SizedBox());
      await controller.onPrepareUpload(_event('no-ui'));
      expect(observer.decisions.last.sessionId, 'no-ui');
      expect(observer.decisions.last.config, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late path failures after abort or service shutdown do not reject a newer request', (tester) async {
    final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService()))]);
    addTearDown(container.disposeContainer);
    ServerState? state = const ServerState(alias: 'Fixture', port: 53317, https: false, session: null, web: null);
    var gate = Completer<String>();
    final controller = ReceiveController(
      ServerUtils(refFunc: () => container, getState: () => state!, getStateOrNull: () => state, setState: (_) => fail('Unexpected state change')),
      resolveDefaultDestination: () => gate.future,
      resolveCache: () => throw StateError('No cache lookup after destination failure'),
    );
    final first = controller.onPrepareUpload(_event('old'));
    controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'old'));
    gate.completeError(const FileSystemException('aborted'));
    await first;
    gate = Completer<String>();
    final previousGate = gate;
    final previous = controller.onPrepareUpload(_event('previous'));
    gate = Completer<String>();
    final newer = controller.onPrepareUpload(_event('newer'));
    previousGate.completeError(const FileSystemException('late old failure'));
    await previous;
    controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'newer'));
    gate.completeError(const FileSystemException('newer aborted'));
    await newer;
    gate = Completer<String>();
    final second = controller.onPrepareUpload(_event('stopped'));
    state = null;
    gate.completeError(const FileSystemException('stopped'));
    await second;
    // Accessing the uninitialized parent provider or Routerino would fail here.
    expect(tester.takeException(), isNull);
  });
}
