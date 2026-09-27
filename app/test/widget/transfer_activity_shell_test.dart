import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:refena_flutter/refena_flutter.dart';

final testActivities = NotifierProvider<TestActivities, List<TransferActivity>>((ref) => TestActivities());

class TestActivities extends PureNotifier<List<TransferActivity>> {
  @override
  List<TransferActivity> init() => [];
  void replace(List<TransferActivity> tasks) => state = tasks;
}

final testNetwork = NotifierProvider<TestNetwork, NetworkState>((_) => TestNetwork());

class TestNetwork extends PureNotifier<NetworkState> {
  @override
  NetworkState init() => const NetworkState(localIps: [], initialized: true);
  void replace(NetworkState next) => state = next;
}

TransferActivity task(String id, TransferDirection direction, {TransferPhase phase = TransferPhase.transferring, int bytes = 25}) => TransferActivity(
  id: id,
  direction: direction,
  phase: phase,
  peer: '$id device',
  files: [TransferActivityFile('$id.bin', 100, bytes)],
);

class RecordingServer extends ServerService {
  String? canceled;
  @override
  ServerState? init() => null;
  @override
  void cancelSession({String? expectedSessionId}) => canceled = expectedSessionId;
}

void main() {
  testWidgets(
    'global badges survive navigation; panel switching preserves tasks and acknowledges only results',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await LocaleSettings.setLocale(AppLocale.en);
      if (const bool.fromEnvironment('CAPTURE_TRANSFER_UI')) {
        await tester.runAsync(() async {
          await (FontLoader('TransferTest')..addFont(rootBundle.load('packages/yaru/assets/fonts/Ubuntu-R.ttf'))).load();
          await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        });
      }
      final key = GlobalKey<NavigatorState>();
      final captureKey = GlobalKey();
      late Ref ref;
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: RefenaScope(
            overrides: [
              networkEnvironmentProvider.overrideWithBuilder((ref) => ref.watch(testNetwork)),
              transferActivityProvider.overrideWithBuilder((ref) => ref.watch(testActivities)),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: key,
                theme: getTheme(ColorMode.localsend, Colors.green, Brightness.light, null).copyWith(
                  textTheme: const bool.fromEnvironment('CAPTURE_TRANSFER_UI')
                      ? getTheme(ColorMode.localsend, Colors.green, Brightness.light, null).textTheme.apply(fontFamily: 'TransferTest')
                      : null,
                ),
                debugShowCheckedModeBanner: false,
                builder: (context, child) {
                  ref = context.ref;
                  return TransferActivityShell(navigatorKey: key, child: child!);
                },
                home: const Scaffold(body: Text('Original page')),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsNothing);
      final tasks = [
        task('outgoing', TransferDirection.send),
        task('incoming', TransferDirection.receive),
        task('failed', TransferDirection.send, phase: TransferPhase.failed),
      ];
      ref.notifier(testActivities).replace(tasks);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-badge-receive')), findsOneWidget);
      unawaited(key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Settings page')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('send:outgoing')));
      await tester.pumpAndSettle();
      expect(find.text('outgoing.bin'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-tab-receive')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receive:incoming')));
      await tester.pumpAndSettle();
      expect(find.text('incoming.bin'), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE_TRANSFER_UI')) {
        await tester.runAsync(() async {
          final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/legnasend-transfer-panel-${debugDefaultTargetPlatformOverride!.name}.png').writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('transfer-tab-send')));
      await tester.pumpAndSettle();
      expect(find.text('outgoing.bin'), findsOneWidget);
      // Global direction entries stay live while the sheet is already open.
      await tester.tap(find.byKey(const ValueKey('transfer-badge-receive')));
      await tester.pumpAndSettle();
      expect(find.text('incoming.bin'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      expect(find.text('outgoing.bin'), findsOneWidget);
      ref.notifier(testActivities).replace([task('outgoing', TransferDirection.send, bytes: 70), tasks[1], tasks[2]]);
      await tester.pumpAndSettle();
      expect(find.text('70 B / 100 B'), findsOneWidget);
      await tester.tap(find.text(t.transferActivity.acknowledge));
      await tester.pumpAndSettle();
      expect(ref.read(acknowledgedTransferResultsProvider), {'send:failed:failed'});
      expect(ref.read(testActivities).length, 3);
      await tester.tap(find.byTooltip(t.transferNavigation.hide));
      await tester.pumpAndSettle();
      expect(find.text('Settings page'), findsOneWidget);
      // Back first leaves details, then hides the list, preserving both tasks.
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('send:outgoing')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('outgoing.bin'), findsNothing);
      expect(find.byKey(const ValueKey('send:outgoing')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Settings page'), findsOneWidget);
      expect(ref.read(testActivities).length, 3);
      // A newly arriving prompt can cover a panel. Refocus only our owned sheet.
      await tester.tap(find.byKey(const ValueKey('transfer-badge-send')));
      await tester.pumpAndSettle();
      unawaited(key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Receive prompt')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-badge-receive')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receive:incoming')), findsOneWidget);
      await tester.tap(find.byTooltip(t.transferNavigation.hide));
      await tester.pumpAndSettle();
      expect(find.text('Receive prompt'), findsOneWidget);
      // Changes while sending and receiving are reflected without touching tasks.
      ref
          .notifier(testNetwork)
          .replace(
            const NetworkState(
              localIps: ['192.168.1.4', '198.18.0.1'],
              initialized: true,
              vpnKnown: true,
              vpnDetected: true,
              proxyKnown: true,
              proxyEnabled: true,
              tunnelInterfaces: ['utun4'],
              addresses: [
                LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.4', prefixLength: 24),
                LocalNetworkAddress(interfaceName: 'utun4', address: '198.18.0.1', prefixLength: 30),
              ],
            ),
          );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('network-environment-badge')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network-environment-badge')));
      await tester.pumpAndSettle();
      expect(find.text(t.networkEnvironment.title), findsOneWidget);
      expect(find.textContaining('192.168.1.4'), findsOneWidget);
      expect(find.textContaining('198.18.0.1'), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE_TRANSFER_UI')) {
        await tester.runAsync(() async {
          final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/legnasend-vpn-dialog-${debugDefaultTargetPlatformOverride!.name}.png').writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      ref.notifier(testNetwork).replace(const NetworkState(localIps: [], initialized: true, vpnKnown: true, proxyKnown: true));
      await tester.pumpAndSettle();
      expect(find.text('${t.networkEnvironment.vpn}: ${t.networkEnvironment.notDetected}'), findsOneWidget);
      expect(find.byKey(const ValueKey('network-environment-badge')), findsNothing);
      await tester.tap(find.text(t.general.close));
      await tester.pumpAndSettle();
      expect(find.text('Receive prompt'), findsOneWidget);
      expect(ref.read(testActivities).length, 3);
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsOneWidget);
      ref.notifier(testActivities).replace([tasks[2]]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-badge-send')), findsNothing);
      ref.notifier(testActivities).replace([task('new-request', TransferDirection.receive, phase: TransferPhase.waiting)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-badge-receive')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
  testWidgets('a late cancel confirmation cannot cancel a new receive task', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final server = RecordingServer();
    final key = GlobalKey<NavigatorState>();
    late Ref ref;
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          networkEnvironmentProvider.overrideWithBuilder((ref) => ref.watch(testNetwork)),
          transferActivityProvider.overrideWithBuilder((ref) => ref.watch(testActivities)),
          serverProvider.overrideWithNotifier((_) => server),
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
    ref.notifier(testActivities).replace([task('old', TransferDirection.receive)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('transfer-badge-receive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('receive:old')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    ref.notifier(testActivities).replace([task('new', TransferDirection.receive)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.cancel).last);
    await tester.pumpAndSettle();
    expect(server.canceled, isNull);
    expect(ref.read(testActivities).single.id, 'new');
    expect(find.text(t.transferActivity.ended), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
