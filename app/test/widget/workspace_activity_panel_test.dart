import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/util/web_transfer_activity_strings.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fixtures/transfer_fixtures.dart';
import '../unit/provider/workspace_transfer_activity_test.dart' show workspaceRecord;

class _Server extends ServerService {
  @override
  ServerState? init() => ServerState(alias: 'Self', port: 53317, https: false, session: incoming('native-receive'), web: null);
}

class _Sends extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {'native-send': outgoing('native-send')};
}

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets(
      'stopped publication uncertainty stays discoverable and never looks successful ${locale.name}',
      (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        final container = RefenaContainer(
          overrides: [
            serverProvider.overrideWithNotifier((_) => _Server()),
            transferActivityProvider.overrideWithBuilder((ref) => ref.watch(webTransferActivityProvider)),
            networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
          ],
        );
        final web = container.notifier(webTransferActivityProvider);
        final pending = jsonEncode([workspaceRecord('publishing', bytes: 100)]);
        web.apply(pending, generation: 1);
        web.stopped(generation: 2, finalSnapshot: pending);
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: key,
                builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
                home: const Scaffold(body: Text('Home')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final badge = find.byKey(const ValueKey('transfer-badge-receive'));
        expect(badge, findsOneWidget);
        expect(find.descendant(of: badge, matching: find.byIcon(Icons.error_outline)), findsOneWidget);
        expect(find.descendant(of: badge, matching: find.byIcon(Icons.task_alt)), findsNothing);
        await tester.tap(badge);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('webResponse:receive:publishing')));
        await tester.pumpAndSettle();
        final labels = WebTransferActivityStrings(locale);
        expect(find.text(labels.unconfirmed), findsOneWidget);
        final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
        expect(bar.value, 1, reason: 'Retain the real received-byte ratio, not a guessed publication result');
        expect(bar.color, Theme.of(tester.element(find.byType(LinearProgressIndicator))).colorScheme.error);
        expect(bar.semanticsLabel, labels.unconfirmed);
        expect(find.text(t.general.cancel), findsNothing);
        await tester.tap(find.byTooltip(labels.help));
        await tester.pumpAndSettle();
        expect(find.text(labels.unknownDetail), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.disposeContainer();
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
  for (final emoji in [false, true]) {
    testWidgets(
      'legal long workspace and relative names wrap at 320px and 1.6 scale emoji=$emoji',
      (tester) async {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await LocaleSettings.setLocale(AppLocale.en);
        final workspaceName = emoji ? '😀' * 120 : 'W' * 480;
        final relativeName = 'nested/${emoji ? '😀' * 4000 : 'f' * 4000}.txt';
        final container = RefenaContainer(
          overrides: [
            serverProvider.overrideWithNotifier((_) => _Server()),
            transferActivityProvider.overrideWithBuilder((ref) => ref.watch(webTransferActivityProvider)),
          ],
        );
        container
            .notifier(webTransferActivityProvider)
            .apply(
              jsonEncode([
                {
                  ...workspaceRecord('long', phase: 'succeeded', bytes: 100),
                  'origin': 'api',
                  'peer': '',
                  'name': relativeName,
                  'workspaceName': workspaceName,
                },
              ]),
              generation: 1,
            );
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: TransferActivityPanel(initialDirection: TransferDirection.receive, initialTaskKey: 'webResponse:receive:long'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final task = container.read(webTransferActivityProvider).single;
        expect(find.text(WebTransferActivityStrings(AppLocale.en).sourceLabel(task)), findsOneWidget);
        final tagText = tester.widget<Text>(find.text(workspaceName));
        expect(tagText.maxLines, 2);
        expect(tagText.overflow, TextOverflow.ellipsis);
        await tester.scrollUntilVisible(find.text(relativeName), 150, scrollable: find.byType(Scrollable).last);
        expect(find.text(relativeName), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.disposeContainer();
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets(
      'workspace snapshot duplex tasks, speed and scoped cancellation at 320px ${locale.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        var clock = 0;
        final commands = <String>[];
        final web = WebTransferActivityNotifier(
          cancelRequest: (id) async {
            commands.add(id);
            return true;
          },
        );
        final container = RefenaContainer(
          overrides: [
            webTransferActivityProvider.overrideWithNotifier((_) => web),
            transferSpeedProvider.overrideWithNotifier((_) => TransferSpeedNotifier(clock: () => clock)),
            serverProvider.overrideWithNotifier((_) => _Server()),
            sendProvider.overrideWithNotifier((_) => _Sends()),
            networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
          ],
        );
        container.read(webTransferActivityProvider);
        void snapshot({int bytes = 25, String upPhase = 'transferring', int generation = 1}) => web.apply(
          jsonEncode([
            workspaceRecord('up', bytes: bytes, phase: upPhase),
            {...workspaceRecord('down', direction: 'send', operation: 'archive', bytes: bytes), 'origin': 'api', 'peer': '', 'total': null},
          ]),
          generation: generation,
        );
        snapshot();
        final progress = container.notifier(fileTransferProvider);
        progress.setStatus(sessionId: 'native-receive', fileId: 'in', status: FileStatus.sending);
        progress.setStatus(sessionId: 'native-send', fileId: 'out', status: FileStatus.sending);
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: key,
                builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
                home: const Scaffold(body: Text('Home')),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(container.read(transferActivityProvider).length, 4);
        expect(find.text('${t.transferActivity.send} 2'), findsOneWidget);
        expect(find.text('${t.transferActivity.receive} 2'), findsOneWidget);
        clock = 1000;
        snapshot(bytes: 75);
        progress.setProgress(sessionId: 'native-receive', fileId: 'in', progress: .5);
        progress.setProgress(sessionId: 'native-send', fileId: 'out', progress: .5);
        await tester.pump(const Duration(milliseconds: 500));
        expect(container.read(transferSpeedProvider)['webResponse:receive:up'], greaterThan(0));
        expect(container.read(transferSpeedProvider)['webResponse:send:down'], greaterThan(0));
        expect(activeTransferProgress(container.read(transferActivityProvider), TransferDirection.receive), .625);
        expect(activeTransferProgress(container.read(transferActivityProvider), TransferDirection.send), isNull);
        await tester.tap(find.byKey(const ValueKey('transfer-badge-receive')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('webResponse:receive:up')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final labels = WebTransferActivityStrings(locale);
        final upload = container.read(webTransferActivityProvider).first;
        expect(find.text('Workspace'), findsOneWidget);
        expect(find.text(labels.operationLabel(upload)), findsOneWidget);
        expect(find.text(labels.detailFor(upload)), findsNothing);
        await tester.tap(find.byTooltip(labels.help));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(labels.detailFor(upload)), findsOneWidget);
        await tester.tap(find.text(t.general.close));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        // A confirmation opened for one generation cannot cancel its replacement.
        await tester.ensureVisible(find.text(t.general.cancel));
        await tester.tap(find.text(t.general.cancel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        snapshot(bytes: 75, generation: 2);
        await tester.tap(find.widgetWithText(ElevatedButton, t.general.cancel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(commands, isEmpty);
        await tester.tap(find.text(t.general.cancel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.widgetWithText(ElevatedButton, t.general.cancel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(commands, ['up']);
        expect(container.read(webTransferActivityProvider).every((task) => task.active), true);
        snapshot(bytes: 75, upPhase: 'canceled', generation: 2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(container.read(webTransferActivityProvider).last.active, true);
        expect(container.read(serverProvider)!.session!.sessionId, 'native-receive');
        expect(container.read(sendProvider).keys, ['native-send']);
        // A later successful upload is a distinct request, not a fabricated
        // canceled-to-success transition for the original request.
        web.apply(
          jsonEncode([
            workspaceRecord('up', bytes: 75, phase: 'canceled'),
            workspaceRecord('saved', bytes: 100, phase: 'succeeded'),
            {...workspaceRecord('down', direction: 'send', operation: 'archive', bytes: 75), 'origin': 'api', 'peer': '', 'total': null},
          ]),
          generation: 2,
        );
        await tester.pump();
        await tester.tap(find.text(t.transferActivity.back));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('webResponse:receive:saved')));
        await tester.pump();
        expect(find.text(labels.phaseFor(container.read(webTransferActivityProvider)[1], 'unused')), findsOneWidget);
        expect(find.text(labels.phase(TransferPhase.succeeded, 'unused')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('transfer-tab-send')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('API'), findsWidgets);
        expect(find.text('ZIP'), findsOneWidget);
        expect(commands, ['up']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.disposeContainer();
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
}
