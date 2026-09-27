import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:refena_flutter/refena_flutter.dart';

final source = NotifierProvider<SpeedActivities, List<TransferActivity>>((ref) => SpeedActivities());

class SpeedActivities extends PureNotifier<List<TransferActivity>> {
  @override
  List<TransferActivity> init() => [];
  void replace(List<TransferActivity> next) => state = next;
}

TransferActivity task(String id, TransferDirection direction, int bytes, {TransferPhase phase = TransferPhase.transferring}) => TransferActivity(
  id: id,
  direction: direction,
  phase: phase,
  peer: 'Device',
  files: [TransferActivityFile('file.bin', 10000000, bytes)],
);

void main() {
  testWidgets(
    'shared sampler separates equal direction IDs, excludes waiting/history, decays and removes finished tasks',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      late Ref ref;
      await LocaleSettings.setLocale(AppLocale.en);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
            transferActivityProvider.overrideWithBuilder((ref) => ref.watch(source)),
            transferSpeedProvider.overrideWithNotifier((_) => TransferSpeedNotifier(clock: () => tester.binding.clock.now().millisecondsSinceEpoch)),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: key,
              builder: (context, child) {
                ref = context.ref;
                return TransferActivityShell(navigatorKey: key, child: child!);
              },
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      ref.notifier(source).replace([
        task('same', TransferDirection.send, 0),
        task('same', TransferDirection.receive, 0),
        task('queued', TransferDirection.send, 9000, phase: TransferPhase.waiting),
      ]);
      await tester.pump();
      await tester.pump();
      expect(ref.read(transferSpeedProvider), {'send:same': null, 'receive:same': null});
      ref.notifier(source).replace([
        task('same', TransferDirection.send, 500),
        task('same', TransferDirection.receive, 1000),
        task('done', TransferDirection.send, 9999, phase: TransferPhase.succeeded),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(ref.read(transferSpeedProvider), {'send:same': 1000, 'receive:same': 2000});
      expect(find.text('1.0 KB/s'), findsOneWidget);
      expect(find.text('2.0 KB/s'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Current speed:'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('send:same')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Current speed:'), findsOneWidget);
      for (var tick = 0; tick < 8; tick++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(ref.read(transferSpeedProvider), {'send:same': 0, 'receive:same': 0});
      // Restored verified bytes are a baseline, not fresh network throughput.
      ref.notifier(source).replace([task('same', TransferDirection.send, 8000000), task('same', TransferDirection.receive, 1000)]);
      ref.notifier(transferSpeedProvider).rebase('send:same');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(ref.read(transferSpeedProvider)['send:same'], isNull);
      expect(ref.read(transferSpeedProvider)['receive:same'], 0);
      ref.notifier(source).replace([task('same', TransferDirection.send, 8001000), task('same', TransferDirection.receive, 1000)]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(ref.read(transferSpeedProvider)['send:same'], 2000);
      ref.notifier(source).replace([task('same', TransferDirection.send, 500, phase: TransferPhase.succeeded)]);
      await tester.pump();
      await tester.pump();
      expect(ref.read(transferSpeedProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );

  test('directional totals include concurrent tasks, not historical throughput', () {
    final tasks = [
      task('a', TransferDirection.send, 20),
      task('b', TransferDirection.send, 30),
      task('a', TransferDirection.receive, 10),
      task('c', TransferDirection.send, 99, phase: TransferPhase.succeeded),
    ];
    const rates = {'send:a': 10, 'send:b': 20, 'receive:a': 40, 'send:c': 999};
    expect(directionalTransferSpeed(rates, tasks, TransferDirection.send), 30);
    expect(directionalTransferSpeed(rates, tasks, TransferDirection.receive), 40);
    expect(directionalTransferSpeed({'send:a': 10}, tasks, TransferDirection.send), isNull);
  });
}
