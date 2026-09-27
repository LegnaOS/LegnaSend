import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

class _SavedDestination extends MockPersistenceService {
  @override
  String? getDestination() => '/authorized/keep';
}

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw]) {
    for (final phase in [SessionStatus.waiting, SessionStatus.sending]) {
      testWidgets('destination loss in ${phase.name} is localized for ${locale.languageTag} and isolated from later sessions', (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        final container = RefenaContainer(overrides: [settingsProvider.overrideWithNotifier((_) => SettingsService(_SavedDestination()))]);
        final progress = container.notifier(fileTransferProvider);
        final original = incoming('current', status: phase);
        final file = original.files['in']!;
        ServerState? state = ServerState(
          alias: 'Receiver',
          port: 53317,
          https: false,
          web: null,
          session: original.copyWith(files: {'in': file, 'done': file, 'skipped': file}),
        );
        progress.setStatus(sessionId: 'current', fileId: 'in', status: FileStatus.sending);
        progress.setStatus(sessionId: 'current', fileId: 'done', status: FileStatus.finished);
        progress.setStatus(sessionId: 'current', fileId: 'skipped', status: FileStatus.skipped);
        final controller = ReceiveController(
          ServerUtils(
            refFunc: () => container,
            getState: () => state!,
            getStateOrNull: () => state,
            setState: (update) => state = update(state),
          ),
        );
        controller.onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent(sessionId: 'current'));
        final failed = state;
        expect(state!.session!.status, SessionStatus.finishedWithErrors);
        expect(state!.session!.endTime, isNotNull);
        expect(state!.session!.destinationDirectory, '/destination');
        expect(state!.session!.files['in']!.errorMessage, t.receivePage.destinationUnavailable);
        expect(progress.getStatus(sessionId: 'current', fileId: 'in'), FileStatus.failed);
        expect(progress.getStatus(sessionId: 'current', fileId: 'done'), FileStatus.finished);
        expect(progress.getStatus(sessionId: 'current', fileId: 'skipped'), FileStatus.skipped);
        expect(state!.session!.files['done']!.errorMessage, isNull);
        expect(state!.session!.files['skipped']!.errorMessage, isNull);
        expect(container.read(settingsProvider).destination, '/authorized/keep');
        // Rust may follow the local grant error with a prepare-aborted event.
        // It must not relabel this failure as a remote cancellation.
        controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'current'));
        controller.onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent(sessionId: 'current'));
        expect(state, same(failed));
        state = state!.copyWith(session: incoming('next', status: SessionStatus.waiting));
        final next = state;
        controller.onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent(sessionId: 'current'));
        controller.onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent(sessionId: 'current'));
        expect(state, same(next));
        expect(container.read(settingsProvider).destination, '/authorized/keep');
        state = null;
        controller.onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent(sessionId: 'current'));
        expect(state, isNull);
        container.disposeContainer();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('destination error never revises a terminal receive result', (tester) async {
    for (final status in SessionStatus.values.where((status) => status != SessionStatus.waiting && status != SessionStatus.sending)) {
      final state = ServerState(
        alias: 'Receiver',
        port: 53317,
        https: false,
        web: null,
        session: incoming('complete', status: status),
      );
      final controller = ReceiveController(
        ServerUtils(
          refFunc: () => throw StateError('Terminal error should not access providers'),
          getState: () => state,
          getStateOrNull: () => state,
          setState: (_) => fail('Terminal session was changed'),
        ),
      );
      controller.onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent(sessionId: 'complete'));
      expect(state.session!.status, status);
    }
  });
}
