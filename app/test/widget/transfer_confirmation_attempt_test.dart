import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

const _id = 'stable-job';

class _Sender extends SendNotifier {
  Object attempt = Object();
  String? canceled;
  @override
  Map<String, SendSessionState> init() => {_id: outgoing(_id)};
  @override
  Object? sessionAttemptIdentity(String sessionId) => sessionId == _id ? attempt : null;
  @override
  void cancelSession(String sessionId) => canceled = sessionId;
  void cancelAttempt() => state = {_id: state[_id]!.copyWith(status: SessionStatus.canceledBySender)};
  void replaceAttempt() {
    attempt = Object();
    state = {
      _id: outgoing(_id).copyWith(files: {'replacement': outgoing(_id).files.values.first.copyWith(file: transferFile('replacement', 100))}),
    };
  }
}

class _Server extends ServerService {
  int epoch = 0, webEpoch = 0;
  String? canceled;
  @override
  int get listenerGeneration => epoch;
  @override
  int get generation => webEpoch;
  @override
  ServerState? init() => ServerState(alias: 'Self', port: 53317, https: false, session: incoming(_id), web: null);
  @override
  void cancelSession({String? expectedSessionId}) => canceled = expectedSessionId;
  void replaceWeb() {
    webEpoch++;
    state = ServerState(alias: 'Self', port: 53317, https: false, session: incoming(_id), web: null);
  }

  void replaceGeneration() {
    epoch++;
    state = ServerState(alias: 'Self', port: 53317, https: false, session: incoming(_id), web: null);
  }
}

class _Queue extends SendQueueNotifier {
  final bool enabled;
  _Queue(this.enabled);
  String? canceled;
  Completer<void>? cancellation;
  int cancelCalls = 0;
  SendJob job(int revision) => SendJob(
    id: _id,
    target: Device.empty,
    files: [queuedFile('out', 100)],
    restored: true,
    status: SendJobStatus.running,
    attemptRevision: revision,
  );
  @override
  List<SendJob> init() => enabled ? [job(0)] : [];
  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
    await cancellation?.future;
    canceled = id;
  }

  void replaceAttempt() => state = [job(1)];
}

class _Speeds extends TransferSpeedNotifier {
  @override
  Map<String, int?> init() => {};
}

void main() {
  for (final fail in [false, true]) {
    testWidgets('progress awaits queued cancellation intent, journal failure=$fail', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final sender = _Sender(), queue = _Queue(true)..cancellation = Completer<void>();
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            sendProvider.overrideWithNotifier((_) => sender),
            serverProvider.overrideWithNotifier((_) => _Server()),
            sendQueueProvider.overrideWithNotifier((_) => queue),
            transferSpeedProvider.overrideWithNotifier((_) => _Speeds()),
            settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      unawaited(
        key.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => ProgressPage(
              showAppBar: true,
              closeSessionOnClose: false,
              sessionId: _id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(t.general.cancel));
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel).last);
      await tester.pumpAndSettle();
      expect(queue.cancelCalls, 1);
      expect(queue.canceled, isNull);
      expect(sender.canceled, isNull, reason: 'must not bypass pending queue intent');
      expect(find.byType(ProgressPage), findsOneWidget);
      if (fail) {
        queue.cancellation!.completeError(StateError('journal save failed'));
      } else {
        queue.cancellation!.complete();
      }
      await tester.pumpAndSettle();
      expect(sender.canceled, isNull);
      if (fail) {
        expect(find.byType(ProgressPage), findsOneWidget);
        expect(find.text(t.general.error), findsOneWidget);
        expect(queue.canceled, isNull);
      } else {
        expect(find.text('Home'), findsOneWidget);
        expect(queue.canceled, _id);
      }
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final panel in [true, false]) {
    for (final replacement in ['job', 'session', 'session-canceled', 'server', 'web']) {
      testWidgets(
        '${panel ? 'panel' : 'progress'} confirmation guards attempt identity during $replacement replacement',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await LocaleSettings.setLocale(AppLocale.en);
          final sender = _Sender(), server = _Server(), queue = _Queue(replacement == 'job');
          final key = GlobalKey<NavigatorState>();
          final receiving = replacement == 'server' || replacement == 'web';
          await tester.pumpWidget(
            RefenaScope(
              overrides: [
                sendProvider.overrideWithNotifier((_) => sender),
                serverProvider.overrideWithNotifier((_) => server),
                sendQueueProvider.overrideWithNotifier((_) => queue),
                transferSpeedProvider.overrideWithNotifier((_) => _Speeds()),
                settingsProvider.overrideWithNotifier((_) => SettingsService(MockPersistenceService())),
                transferActivityProvider.overrideWithBuilder(
                  (ref) => [
                    TransferActivity(
                      id: _id,
                      direction: receiving ? TransferDirection.receive : TransferDirection.send,
                      phase: TransferPhase.transferring,
                      peer: 'Peer',
                      files: const [TransferActivityFile('file.bin', 100, 20)],
                      job: ref.watch(sendQueueProvider).firstOrNull,
                    ),
                  ],
                ),
              ],
              child: TranslationProvider(
                child: MaterialApp(
                  navigatorKey: key,
                  theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null),
                  home: const Scaffold(body: Text('Home')),
                ),
              ),
            ),
          );
          if (panel) {
            unawaited(
              showModalBottomSheet<void>(
                context: key.currentState!.overlay!.context,
                isScrollControlled: true,
                builder: (_) => TransferActivityPanel(initialDirection: receiving ? TransferDirection.receive : TransferDirection.send),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(ValueKey('${receiving ? 'receive' : 'send'}:$_id')));
          } else {
            unawaited(
              key.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => ProgressPage(
                    showAppBar: true,
                    closeSessionOnClose: false,
                    sessionId: _id,
                    receiving: receiving,
                  ),
                ),
              ),
            );
          }
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(t.general.cancel));
          await tester.pumpAndSettle();
          await tester.tap(find.text(t.general.cancel));
          await tester.pumpAndSettle();
          expect(find.text(t.general.cancel), findsNWidgets(2));
          switch (replacement) {
            case 'job':
              queue.replaceAttempt();
            case 'session':
              sender.replaceAttempt();
            case 'session-canceled':
              sender.replaceAttempt();
              sender.cancelAttempt();
            case 'server':
              server.replaceGeneration();
            case 'web':
              server.replaceWeb();
          }
          await tester.pumpAndSettle();
          // A replacement may remove the old owned progress route, never the
          // still-open confirmation or the underlying unrelated home route.
          expect(find.text(t.general.cancel).last, findsOneWidget);
          await tester.tap(find.text(t.general.cancel).last);
          await tester.pumpAndSettle();
          expect(sender.canceled, isNull);
          expect(server.canceled, replacement == 'web' ? _id : isNull);
          expect(queue.canceled, isNull);
          if (!panel) expect(find.text('Home'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
      );
    }
  }
}
