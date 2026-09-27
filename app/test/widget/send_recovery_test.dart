import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/util/send_recovery_strings.dart';
import 'package:localsend_app/widget/send_queue_panel.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';

class _Jobs extends SendQueueNotifier {
  final List<SendJob> initial;
  final retried = <String>[];
  _Jobs(this.initial);
  @override
  List<SendJob> init() => initial;
  @override
  void retry(SendJob job) => retried.add(job.id);
}

class _Sends extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {};
}

SendJob restored({bool checking = false, String? issue, bool done = false}) => SendJob(
  id: 'restored',
  target: Device.empty.copyWith(alias: 'Receiving device'),
  files: [queuedFile('complete', 100), queuedFile('skipped', 200), queuedFile('remaining', 300)],
  status: done ? SendJobStatus.succeeded : SendJobStatus.failed,
  restored: true,
  completedIndices: done ? {0, 2} : {0},
  skippedIndices: {1},
  recoveryChecking: checking,
  recoveryIssue: issue,
  error: '/private/credentials/secret.json',
);

void expectCompactRecoveryCopy() {
  for (final text in ['Nothing is sent automatically.', '不会自动发送。', '不會自動傳送。']) {
    expect(find.textContaining(text), findsNothing);
  }
}

void main() {
  test('restored outcomes credit only confirmed bytes and exclude skipped files', () {
    final task = collectTransferActivities(jobs: [restored()], sends: {}, receive: null, progress: FileTransferNotifier()).single;
    expect(task.totalBytes, 400);
    expect(task.transferredBytes, 100);
    expect(task.progress, .25);
    expect(task.files.map((f) => f.name), ['complete.bin', 'remaining.bin']);
    final done = collectTransferActivities(jobs: [restored(done: true)], sends: {}, receive: null, progress: FileTransferNotifier()).single;
    expect(done.progress, 1);
    expect(done.phase, TransferPhase.succeeded);
  });

  test('live recovery subset includes earlier confirmation once and maps duplicate sources by attempt index', () {
    final first = outgoing('recovered', size: 100).files.values.single;
    final second = outgoing('other', size: 300).files.values.single.copyWith(file: transferFile('second', 300));
    final session = outgoing('recovered').copyWith(files: {'out': first, 'second': second});
    final job = SendJob(
      id: 'recovered',
      target: Device.empty,
      files: [queuedFile('out', 100), queuedFile('out', 100), queuedFile('skip', 200), queuedFile('other', 300)],
      status: SendJobStatus.running,
      restored: true,
      completedIndices: {0, 1},
      skippedIndices: {2},
    ).withAttempt([1, 3]);
    final progress = FileTransferNotifier()
      ..setStatus(sessionId: 'recovered', fileId: 'out', status: FileStatus.finished)
      ..setStatus(sessionId: 'recovered', fileId: 'second', status: FileStatus.sending)
      ..setProgress(sessionId: 'recovered', fileId: 'second', progress: .5);
    final task = collectTransferActivities(jobs: [job], sends: {'recovered': session}, receive: null, progress: progress).single;
    expect(task.totalBytes, 500);
    expect(task.transferredBytes, 350);
    expect(task.files.map((file) => file.transferred), [100, 100, 150]);
    // The newest checkpoint must not change the immutable mapping mid-attempt.
    expect(job.withCheckpoints({0, 1}, {2}).withStatus(SendJobStatus.failed).withRecovery(checking: true).attemptIndices, [1, 3]);
    // If the attempt map is absent, never infer progress from duplicate names.
    final unmapped = SendJob(
      id: job.id,
      target: job.target,
      files: job.files,
      restored: true,
      status: SendJobStatus.running,
      completedIndices: {0},
      skippedIndices: {2},
    );
    final conservative = collectTransferActivities(jobs: [unmapped], sends: {'recovered': session}, receive: null, progress: progress).single;
    expect(conservative.transferredBytes, 100);
  });

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('recovered queue wraps at 320px large text in ${locale.name}; continue is explicit', (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final strings = SendRecoveryStrings(locale);
      final jobs = _Jobs([restored(issue: 'peerUnavailable')]);
      final container = RefenaContainer(
        overrides: [
          sendQueueProvider.overrideWithNotifier((_) => jobs),
          sendProvider.overrideWithNotifier((_) => _Sends()),
        ],
      );
      addTearDown(container.disposeContainer);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(body: SingleChildScrollView(child: SendQueuePanel())),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(strings.restored), findsOneWidget);
      expect(find.text(strings.summary(1, 1, 1)), findsOneWidget);
      expectCompactRecoveryCopy();
      expect(find.text(strings.issue('peerUnavailable')), findsOneWidget);
      expect(find.textContaining('secret.json'), findsNothing);
      expect(jobs.retried, isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('send-retry-restored')));
      await tester.tap(find.byKey(const ValueKey('send-retry-restored')));
      expect(jobs.retried, ['restored']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('checking disables continue and deletion; completed recovery has no continue', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    for (final job in [restored(checking: true), restored(done: true)]) {
      final container = RefenaContainer(
        overrides: [
          sendQueueProvider.overrideWithNotifier((_) => _Jobs([job])),
          sendProvider.overrideWithNotifier((_) => _Sends()),
        ],
      );
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: const MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: SendQueuePanel())),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (job.recoveryChecking) {
        final retry = tester.widget<TextButton>(find.byKey(const ValueKey('send-retry-restored')));
        expect(retry.onPressed, isNull);
        expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == t.general.delete)).onPressed, isNull);
      } else {
        expect(find.byKey(const ValueKey('send-retry-restored')), findsNothing);
        expect(find.text(const SendRecoveryStrings(AppLocale.en).completed), findsOneWidget);
        expectCompactRecoveryCopy();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.disposeContainer();
    }
  });

  testWidgets('global storage or corruption issue is visible even when all jobs failed to load', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final container = RefenaContainer(
      overrides: [
        sendQueueProvider.overrideWithNotifier((_) => _Jobs([])),
        sendProvider.overrideWithNotifier((_) => _Sends()),
      ],
    );
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: SendQueuePanel())),
          ),
        ),
      ),
    );
    for (final issue in ['storage', 'corrupt', 'cleanupStorage']) {
      container.notifier(sendRecoveryIssueProvider).report(issue);
      await tester.pumpAndSettle();
      expect(find.text(const SendRecoveryStrings(AppLocale.en).issue(issue)), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('activity recovery detail wraps at 320px large text in ${locale.name}', (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final jobs = _Jobs([restored()]);
      final tasks = collectTransferActivities(jobs: jobs.initial, sends: {}, receive: null, progress: FileTransferNotifier());
      final container = RefenaContainer(
        overrides: [
          sendQueueProvider.overrideWithNotifier((_) => jobs),
          sendProvider.overrideWithNotifier((_) => _Sends()),
          transferActivityProvider.overrideWithBuilder((_) => tasks),
        ],
      );
      addTearDown(container.disposeContainer);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(body: TransferActivityPanel(initialDirection: TransferDirection.send)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Receiving device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receiving device'));
      await tester.pumpAndSettle();
      expect(find.text('100 B / 400 B'), findsOneWidget);
      expectCompactRecoveryCopy();
      expect(find.textContaining('secret.json'), findsNothing);
      expect(find.text('skipped.bin'), findsNothing);
      await tester.ensureVisible(find.text(SendRecoveryStrings(locale).resume));
      await tester.pumpAndSettle();
      await tester.tap(find.text(SendRecoveryStrings(locale).resume));
      expect(jobs.retried, ['restored']);
      expect(tester.takeException(), isNull);
    });
  }

  test('all recovery issues use user-facing locale copy and unknown issues are not echoed', () {
    for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
      final strings = SendRecoveryStrings(locale);
      for (final issue in [
        'sourceMissing',
        'sourceChanged',
        'sourcePermission',
        'unsupported',
        'peerUnavailable',
        'storage',
        'cleanupStorage',
        'corrupt',
        'busy',
      ]) {
        expect(strings.issue(issue), isNot(equals(issue)));
      }
      expect(strings.issue('/private/token.json'), isNot(contains('/private')));
    }
  });
}
