import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/api/server.dart' as rust;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

import '../mocks.mocks.dart';

class _Parent extends Fake implements ParentIsolateState {}

class _Server extends ServerService {
  @override
  ServerState? init() => const ServerState(alias: 'Self', port: 53317, https: false, session: null, web: null);
  ServerState? get current => state;
  void update(ServerState? Function(ServerState?) transform) => state = transform(state);
}

HttpServerPrepareUploadEvent _prepare(String id) => HttpServerPrepareUploadEvent(
  sessionId: id,
  ip: '127.0.0.1',
  certFingerprint: null,
  info: const rust.RegisterDtoV2(alias: 'Peer', version: '2.2', fingerprint: 'peer', port: 53317, protocol: rust.ProtocolType.http, download: false),
  files: {'file': rust.FileDto(id: 'file', fileName: '$id.bin', size: BigInt.from(100), fileType: 'application/octet-stream')},
);

class _HistoryStorage extends MockPersistenceService {
  List<ReceiveHistoryEntry> disk = [];
  @override
  bool isSaveToHistory() => true;
  @override
  List<ReceiveHistoryEntry> getReceiveHistory() => disk;
  @override
  Future<void> setReceiveHistory(List<ReceiveHistoryEntry>? entries, {DateTime? clearedThrough}) async => disk = List.of(entries!);
}

void main() {
  for (final terminal in ['late-receipt']) {
    testWidgets(
      '$terminal records old published file without altering actual new prompt',
      (tester) async {
        await LocaleSettings.setLocale(AppLocale.en);
        final service = _Server();
        final historyStorage = _HistoryStorage();
        final container = RefenaContainer(
          overrides: [
            persistenceProvider.overrideWithValue(historyStorage),
            serverProvider.overrideWithNotifier((_) => service),
            parentIsolateProvider.overrideWithReducer(
              notifier: (_) => IsolateController(initialState: _Parent()),
              reducer: {IsolateHttpServerPrepareUploadDecisionAction: (state) => state},
            ),
          ],
        );
        final controller = ReceiveController(
          ServerUtils(
            refFunc: () => container,
            getState: () => service.current!,
            getStateOrNull: () => service.current,
            setState: service.update,
          ),
          resolveDefaultDestination: () async => '/destination',
          resolveCache: () async => '/cache',
        );
        container.notifier(serverProvider);
        final progress = container.notifier(fileTransferProvider);
        progress.setStatus(sessionId: 'send', fileId: 'out', status: FileStatus.sending);
        progress.setProgress(sessionId: 'send', fileId: 'out', progress: 0.42);
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: Routerino.navigatorKey,
                home: const Scaffold(body: Text('Home')),
              ),
            ),
          ),
        );
        unawaited(
          Routerino.navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Outgoing progress')))),
        );
        await tester.pumpAndSettle();
        await controller.onPrepareUpload(_prepare('old'));
        await tester.pumpAndSettle();
        final oldWidget = tester.widget<ReceivePage>(find.byType(ReceivePage));
        final oldActions = container.read(oldWidget.vm);
        expect(service.current!.session!.status, SessionStatus.waiting);
        controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'old', reason: rust.SessionEndReasonV2.finished));
        await controller.onPrepareUpload(_prepare('next'));
        await tester.pumpAndSettle();
        expect(find.byType(ReceivePage), findsOneWidget);
        final nextWidget = tester.widget<ReceivePage>(find.byType(ReceivePage));
        expect(container.read(nextWidget.vm).sessionId, 'next');
        expect(service.current!.session!.status, SessionStatus.waiting);
        final nextSession = service.current!.session;
        final event = HttpServerFileUploadResultEvent(
          sessionId: 'old',
          fileId: 'file',
          path: '/destination/old.bin',
          savedToGallery: false,
          error: null,
          receipt: HttpServerReceiveReceipt(
            receiptId: 'native:old-file',
            fileName: 'old.bin',
            fileType: FileType.other,
            fileSize: 100,
            senderAlias: 'Old peer',
            timestamp: DateTime.utc(2026, 9, 25),
          ),
        );
        await controller.onFileUploadResult(event);
        await controller.onFileUploadResult(event);
        await tester.pumpAndSettle();
        expect(service.current!.session, same(nextSession));
        expect(find.byType(ReceivePage), findsOneWidget);
        expect(container.read(nextWidget.vm).sessionId, 'next');
        expect(historyStorage.disk.single.id, 'native:old-file');
        expect(container.read(receiveHistoryProvider).single.senderAlias, 'Old peer');
        oldActions.onAccept();
        oldActions.onDecline();
        oldActions.onClose();
        controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'old', reason: rust.SessionEndReasonV2.cancelled));
        controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'old'));
        await tester.pumpAndSettle();
        expect(service.current!.session!.sessionId, 'next');
        expect(service.current!.session!.status, SessionStatus.waiting);
        expect(progress.getData().containsKey('old'), false);
        expect(progress.getProgress(sessionId: 'send', fileId: 'out'), 0.42);
        final accept = tester.widget<ElevatedButton>(find.ancestor(of: find.text(t.general.accept), matching: find.byType(ElevatedButton)));
        expect(accept.onPressed, isNotNull);
        await tester.tap(find.text(t.general.decline));
        await tester.pumpAndSettle();
        expect(service.current!.session, isNull);
        expect(find.text('Outgoing progress'), findsOneWidget);
        expect(progress.getProgress(sessionId: 'send', fileId: 'out'), 0.42);
        expect(tester.takeException(), isNull);
        controller.onServerStopped();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
}
