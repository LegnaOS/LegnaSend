import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:localsend_app/widget/dialogs/workspace_capture_cleanup_dialog.dart';
import 'package:localsend_app/widget/dialogs/workspace_capture_cleanup_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _Held extends WorkspaceCaptureStore {
  final calls = <Completer<CaptureCleanupReport>>[];
  _Held(super.root) : super.leaseProbe();
  @override
  bool get initialized => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> close() async {}
  @override
  Future<CaptureCleanupReport> cleanup({int limit = 128}) {
    final next = Completer<CaptureCleanupReport>();
    calls.add(next);
    return next.future;
  }
}

class _Provider extends WorkspaceCaptureStoreNotifier {
  final WorkspaceCaptureStore store;
  _Provider(this.store);
  @override
  WorkspaceCaptureStore init() => store;
}

void main() {
  for (final locale in ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    testWidgets('export cleanup is explicit, bounded and cumulative at narrow scale $locale', (tester) async {
      late Directory root;
      late _Held store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('export-ui-');
        store = _Held(root);
        await store.initialize();
      });
      final container = RefenaContainer(overrides: [workspaceCaptureStoreProvider.overrideWithNotifier((_) => _Provider(store))]);
      final strings = WorkspaceCaptureCleanupStrings(locale);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => WorkspaceCaptureCleanupDialog(locale: locale),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(store.calls, isEmpty);
      await tester.ensureVisible(find.text(strings.clean));
      await tester.tap(find.text(strings.clean));
      await tester.pump();
      expect(store.calls.length, 1);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      store.calls[0].complete(
        const CaptureCleanupReport(examined: 128, removedStages: 2, removedFiles: 3, unlinkedBytes: 300, retained: 1, budgetReached: true),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 101));
      expect(store.calls.length, 2);
      store.calls[1].complete(const CaptureCleanupReport(examined: 2, active: 1, failed: 1));
      await tester.pumpAndSettle();
      final state = container.read(workspaceCaptureMaintenanceProvider);
      expect(state.report!.examined, 130);
      expect(state.report!.unlinkedBytes, 300);
      expect(state.report!.removedFiles, 3);
      expect(state.report!.failed, 1);
      expect(state.report!.budgetReached, false);
      expect(state.busy, false);
      expect(state.batches, 2);
      expect(find.text(strings.partial), findsOneWidget);
      expect(find.text(strings.retry), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(strings.retry));
      await tester.tap(find.text(strings.retry));
      await tester.pump();
      expect(store.calls.length, 3);
      await tester.ensureVisible(find.text(strings.close));
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      store.calls[2].complete(const CaptureCleanupReport(examined: 1, removedStages: 1, removedFiles: 1, unlinkedBytes: 25));
      await tester.pumpAndSettle();
      expect(container.read(workspaceCaptureMaintenanceProvider).report!.unlinkedBytes, 25);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(store.calls.length, 3);
      expect(find.text(strings.completed), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        container.disposeContainer();
        await store.close();
        await root.delete(recursive: true);
      });
    });
  }
  testWidgets('operation exceptions preserve completed batches and allow retry', (tester) async {
    late Directory root;
    late _Held store;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('export-errors-');
      store = _Held(root);
      await store.initialize();
    });
    final container = RefenaContainer(overrides: [workspaceCaptureStoreProvider.overrideWithNotifier((_) => _Provider(store))]);
    final service = container.notifier(workspaceCaptureStoreProvider);
    final first = service.clean();
    final duplicate = service.clean();
    expect(identical(first, duplicate), true);
    await tester.pump();
    store.calls[0].complete(const CaptureCleanupReport(removedFiles: 2, unlinkedBytes: 8, budgetReached: true));
    await first;
    await tester.pump(const Duration(milliseconds: 101));
    store.calls[1].completeError(const FileSystemException('offline'));
    await tester.pump();
    final failed = container.read(workspaceCaptureMaintenanceProvider);
    expect(failed.interrupted, true);
    expect(failed.report!.unlinkedBytes, 8);
    expect(failed.busy, false);
    final retry = service.clean();
    await tester.pump();
    store.calls[2].complete(const CaptureCleanupReport());
    await retry;
    expect(container.read(workspaceCaptureMaintenanceProvider).interrupted, false);
    await tester.runAsync(() async {
      container.disposeContainer();
      await store.close();
      await root.delete(recursive: true);
    });
  });
}
