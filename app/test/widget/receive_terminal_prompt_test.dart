import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
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
void main() {
  for (final terminal in ['pending-abort', 'pending-cancel', 'active-cancel', 'failed-cancel', 'finished-success', 'finished-failure']) {
    testWidgets(
      'next receive prompt remains usable after $terminal without closing sending',
      (tester) async {
        await LocaleSettings.setLocale(AppLocale.en);
        final service = _Server();
        final container = RefenaContainer(
          overrides: [
            persistenceProvider.overrideWithValue(MockPersistenceService()),
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
        if (!terminal.startsWith('pending')) {
          service.update(
            (state) => state!.copyWith(
              session: state.session!.copyWith(
                status: terminal == 'failed-cancel' ? SessionStatus.finishedWithErrors : SessionStatus.sending,
                files: {for (final entry in state.session!.files.entries) entry.key: entry.value.copyWith(desiredName: entry.value.file.fileName)},
              ),
            ),
          );
          progress.setStatus(sessionId: 'old', fileId: 'file', status: terminal == 'failed-cancel' ? FileStatus.failed : FileStatus.sending);
        }
        if (terminal == 'pending-abort') {
          controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'old'));
        } else if (terminal.startsWith('finished')) {
          controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'old', reason: rust.SessionEndReasonV2.finished));
          await controller.onFileUploadResult(
            HttpServerFileUploadResultEvent(
              sessionId: 'old',
              fileId: 'file',
              path: terminal == 'finished-success' ? '/destination/old.bin' : null,
              savedToGallery: false,
              error: terminal == 'finished-failure' ? 'post-processing failed' : null,
            ),
          );
        } else {
          controller.onSessionEnd(HttpServerSessionEndEvent(sessionId: 'old', reason: rust.SessionEndReasonV2.cancelled));
        }
        await tester.pumpAndSettle();
        await controller.onPrepareUpload(_prepare('next'));
        await tester.pumpAndSettle();
        expect(find.byType(ReceivePage), findsOneWidget);
        final nextWidget = tester.widget<ReceivePage>(find.byType(ReceivePage));
        expect(container.read(nextWidget.vm).sessionId, 'next');
        expect(service.current!.session!.status, SessionStatus.waiting);
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
