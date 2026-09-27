import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/directory_upload_approval.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/directory_upload_approval_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/util/directory_upload_approval_strings.dart';
import 'package:localsend_app/widget/directory_upload_approval_panel.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:refena_flutter/refena_flutter.dart';

DirectoryUploadApproval request(String id, {int count = 1, int? expiresAt, List<DirectoryUploadApprovalFile>? files}) => DirectoryUploadApproval(
  requestId: id,
  workspaceId: 'workspace-id',
  workspaceName: 'My shared workspace 工作区',
  peerIp: '192.168.1.23',
  expiresAt: expiresAt ?? DateTime.now().add(const Duration(seconds: 60)).millisecondsSinceEpoch,
  files: files ?? List.generate(count, (i) => DirectoryUploadApprovalFile(path: 'folder/file-$i-中文.txt', size: 123, directory: false)),
);

class _Server extends ServerService {
  int cancellations = 0;
  @override
  ServerState? init() => null;
  @override
  void cancelSession({String? expectedSessionId}) {
    cancellations++;
  }
}

void main() {
  test('one batch immutable snapshot; duplicate decisions call only its exact responder once', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider);
    final files = [const DirectoryUploadApprovalFile(path: 'a', size: 10, directory: false)];
    final completion = Completer<void>();
    final calls = <bool>[];
    notifier.add(
      request('one', files: files),
      respond: (accept) {
        calls.add(accept);
        return completion.future;
      },
    );
    files.clear();
    expect(container.read(directoryUploadApprovalProvider).single.files, hasLength(1));
    final decision = notifier.decide('one', true);
    await notifier.decide('one', false);
    expect(calls, [true]);
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.responding);
    completion.complete();
    await decision;
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.accepted);
  });

  test('aborted request and late responder cannot touch a replacement batch; clear keeps pending', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider);
    final completion = Completer<void>();
    notifier.add(request('old'), respond: (_) => completion.future);
    final decision = notifier.decide('old', true);
    notifier.aborted('old');
    notifier.add(request('new'), respond: (_) async {});
    completion.complete();
    await decision;
    notifier.clearFinished();
    expect(container.read(directoryUploadApprovalProvider).map((r) => r.requestId), ['new']);
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.waiting);
    await notifier.decide('new', false);
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.declined);
  });

  test('reused request IDs do not let an old completion approve or disarm a new request', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider);
    final old = Completer<void>(), replacement = Completer<void>();
    notifier.add(request('same'), respond: (_) => old.future);
    final oldDecision = notifier.decide('same', true);
    notifier.aborted('same');
    notifier.add(request('same'), respond: (_) => replacement.future);
    final newDecision = notifier.decide('same', false);
    old.complete();
    await oldDecision;
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.responding);
    replacement.complete();
    await newDecision;
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.declined);
  });

  test('expired deadlines never call responder; errors stay generic and history is capped', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider);
    var calls = 0;
    notifier.add(
      request('expired', expiresAt: 1),
      respond: (_) async {
        calls++;
      },
    );
    await notifier.decide('expired', true);
    expect(calls, 0);
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.expired);
    notifier.add(request('failed'), respond: (_) async => throw StateError('/private/tokens/secret'));
    await notifier.decide('failed', true);
    expect(container.read(directoryUploadApprovalProvider).last.status, DirectoryUploadApprovalStatus.failed);
    for (var i = 0; i < 30; i++) {
      notifier.add(request('expired-$i', expiresAt: 1), respond: (_) async {});
    }
    expect(container.read(directoryUploadApprovalProvider), hasLength(20));
  });

  test('server stop clears pending responders only and ignores in-flight success', () async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider), completion = Completer<void>();
    notifier.add(request('done'), respond: (_) async {});
    await notifier.decide('done', false);
    notifier.add(request('pending'), respond: (_) => completion.future);
    final decision = notifier.decide('pending', true);
    notifier.abortAll();
    completion.complete();
    await decision;
    expect(container.read(directoryUploadApprovalProvider).map((r) => r.requestId), ['done']);
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.declined);
  });

  testWidgets('server deadline expires waiting and ignores a response completing after local timeout', (tester) async {
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final notifier = container.notifier(directoryUploadApprovalProvider);
    final completion = Completer<void>();
    notifier.add(request('timeout'), respond: (_) => completion.future);
    final decision = notifier.decide('timeout', true);
    await tester.pump(const Duration(seconds: 61));
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.expired);
    completion.complete();
    await decision;
    expect(container.read(directoryUploadApprovalProvider).single.status, DirectoryUploadApprovalStatus.expired);
  });

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('batch approval ${locale.name} wraps at 320px with large text and renders only bounded entries', (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final container = RefenaContainer();
      addTearDown(container.disposeContainer);
      final notifier = container.notifier(directoryUploadApprovalProvider);
      final calls = <bool>[];
      notifier.add(
        request('batch', count: 5000),
        respond: (accept) async {
          calls.add(accept);
        },
      );
      final labels = DirectoryUploadApprovalStrings(locale);
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(body: DirectoryUploadApprovalPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(labels.summary(5000, 0)), findsOneWidget);
      expect(find.text(labels.showing(5000)), findsOneWidget);
      expect(find.textContaining('file-4999-'), findsNothing);
      expect(find.byType(Text).evaluate().length, lessThan(60));
      expect(calls, isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('workspace-accept-batch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-accept-batch')));
      await tester.pumpAndSettle();
      expect(calls, [true]);
      await tester.drag(find.byType(ListView).first, const Offset(0, 1600));
      await tester.pumpAndSettle();
      expect(find.text(labels.status(DirectoryUploadApprovalStatus.accepted)), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-accept-batch')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('global request tag survives duplex activity and navigation; hiding is neither reject nor cancel', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final navigator = GlobalKey<NavigatorState>(), server = _Server();
    final container = RefenaContainer(
      overrides: [
        serverProvider.overrideWithNotifier((_) => server),
        networkEnvironmentProvider.overrideWithBuilder((_) => const NetworkState(localIps: [], initialized: true)),
        transferActivityProvider.overrideWithBuilder(
          (_) => [
            const TransferActivity(id: 'out', direction: TransferDirection.send, phase: TransferPhase.transferring, peer: 'out', files: []),
            const TransferActivity(id: 'in', direction: TransferDirection.receive, phase: TransferPhase.transferring, peer: 'in', files: []),
          ],
        ),
      ],
    );
    addTearDown(container.disposeContainer);
    final calls = <bool>[];
    container
        .notifier(directoryUploadApprovalProvider)
        .add(
          request('batch'),
          respond: (accept) async {
            calls.add(accept);
          },
        );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            builder: (_, child) => TransferActivityShell(navigatorKey: navigator, child: child!),
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transfer-badge-send')), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-badge-receive')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-upload-approval-badge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(const DirectoryUploadApprovalStrings(AppLocale.en).hide));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(server.cancellations, 0);
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Settings')))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-upload-approval-badge')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(calls, isEmpty);
    expect(server.cancellations, 0);
    await tester.tap(find.byKey(const ValueKey('workspace-upload-approval-badge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-decline-batch')));
    await tester.pumpAndSettle();
    expect(calls, [false]);
    expect(server.cancellations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('absolute path metadata is not displayed in the approval list', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    container
        .notifier(directoryUploadApprovalProvider)
        .add(
          request(
            'unsafe',
            files: [
              const DirectoryUploadApprovalFile(path: '/private/secret/source.txt', size: 1, directory: false),
              const DirectoryUploadApprovalFile(path: 'C:\\Users\\private.txt', size: 1, directory: false),
            ],
          ),
          respond: (_) async {},
        );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: TranslationProvider(
          child: const MaterialApp(home: Scaffold(body: DirectoryUploadApprovalPanel())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('private'), findsNothing);
    expect(find.text('Name unavailable'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
}
