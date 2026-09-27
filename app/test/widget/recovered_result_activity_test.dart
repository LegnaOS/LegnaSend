import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/util/send_queue.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';

class _Server extends ServerService {
  @override
  ServerState? init() => null;
}

class _Jobs extends SendQueueNotifier {
  int attempts = 0;
  late final queue = SendQueue(
    execute: (_) async {
      attempts++;
      throw StateError('source changed before session creation');
    },
    abort: (_) {},
    onChanged: (jobs) => state = jobs,
  );
  @override
  List<SendJob> init() => [];
  @override
  void dispose() {
    queue.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets(
    'acknowledged recovered failure resurfaces after a real queue preflight retry fails',
    (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final jobs = _Jobs();
      final container = RefenaContainer(
        overrides: [
          sendQueueProvider.overrideWithNotifier((_) => jobs),
          serverProvider.overrideWithNotifier((_) => _Server()),
          networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
        ],
      );
      container.notifier(sendQueueProvider);
      jobs.queue.restore([
        SendJob(
          id: 'restored',
          target: Device.empty.copyWith(alias: 'Receiver'),
          files: [queuedFile('source', 100)],
          status: SendJobStatus.failed,
          restored: true,
        ),
      ]);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
              home: const Scaffold(body: Text('Page')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final old = container.read(transferActivityProvider).single;
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.transferActivity.acknowledge));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsNothing);
      expect(container.read(acknowledgedTransferResultsProvider), contains(old.resultKey));
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      jobs.queue.resume(jobs.queue.jobs.single);
      await tester.pumpAndSettle();
      expect(jobs.attempts, 1);
      expect(container.read(transferActivityProvider).single.resultKey, isNot(old.resultKey));
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      expect(find.text('Receiver'), findsOneWidget);
      expect(jobs.queue.jobs.single.status, SendJobStatus.failed);
      expect(jobs.attempts, 1, reason: 'Opening the new result never schedules an extra retry');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.disposeContainer();
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.android, TargetPlatform.iOS}),
  );
}
