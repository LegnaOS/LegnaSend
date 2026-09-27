import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:localsend_isolates/rust/api/server.dart' as native;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

final workspaceCaptureStoreProvider = NotifierProvider<WorkspaceCaptureStoreNotifier, WorkspaceCaptureStore?>(
  (ref) => WorkspaceCaptureStoreNotifier(),
);
final _log = Logger('WorkspaceCaptureStore');

@immutable
class WorkspaceCaptureMaintenanceState {
  final CaptureCleanupReport? report;
  final bool busy, interrupted;
  final int batches;
  const WorkspaceCaptureMaintenanceState({this.report, this.busy = false, this.interrupted = false, this.batches = 0});
}

final workspaceCaptureMaintenanceProvider = NotifierProvider<WorkspaceCaptureMaintenanceNotifier, WorkspaceCaptureMaintenanceState>(
  (ref) => WorkspaceCaptureMaintenanceNotifier(),
);

class WorkspaceCaptureMaintenanceNotifier extends PureNotifier<WorkspaceCaptureMaintenanceState> {
  @override
  WorkspaceCaptureMaintenanceState init() => const WorkspaceCaptureMaintenanceState();
  void start({required bool continuation}) => state = WorkspaceCaptureMaintenanceState(
    report: continuation ? state.report : null,
    batches: continuation ? state.batches : 0,
    busy: true,
  );
  void complete(CaptureCleanupReport report) => state = WorkspaceCaptureMaintenanceState(
    report: CaptureCleanupReport.fromJson({
      ...(state.report ?? const CaptureCleanupReport()).plus(report).toJson(),
      'budgetReached': report.budgetReached,
    }),
    batches: state.batches + 1,
    busy: report.budgetReached,
  );
  void fail() => state = WorkspaceCaptureMaintenanceState(report: state.report, batches: state.batches, interrupted: true);
}

class WorkspaceCaptureStoreNotifier extends Notifier<WorkspaceCaptureStore?> {
  bool _disposed = false;
  Timer? _cleanupTimer;
  Future<void>? _cleaning;
  bool _initialReportPublished = false;
  @override
  WorkspaceCaptureStore? init() {
    final recovery = ref.read(sendRecoveryStoreProvider);
    return recovery == null
        ? null
        : WorkspaceCaptureStore(
            Directory(p.join(recovery.root.parent.path, '.legnasend-workspace-captures')),
            removeStage: (root, id) => native.cleanupWorkspaceCapture(root: root, id: id),
          );
  }

  Future<WorkspaceCaptureStore> ready() async {
    final store = state;
    if (_disposed || store == null) throw StateError('Capture storage unavailable');
    await store.initialize();
    if (_disposed) throw StateError('Capture storage closed');
    final initial = store.initialCleanupReport;
    if (!_initialReportPublished && initial != null) {
      _initialReportPublished = true;
      final progress = ref.notifier(workspaceCaptureMaintenanceProvider);
      progress.start(continuation: false);
      progress.complete(initial);
      _continueIfNeeded(initial);
    }
    return store;
  }

  Future<void> initialize() => clean();

  /// Opening/closing a dialog does not own this operation. Calls share one run.
  Future<void> clean() {
    if (_disposed || state == null) return Future<void>.value();
    // A subscriber may request another pass before the current Future completes.
    // Coalesce first; never consume its newly scheduled continuation timer.
    if (_cleaning != null) return _cleaning!;
    final continuation = _cleanupTimer != null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    return _cleaning ??= _clean(continuation: continuation).whenComplete(() => _cleaning = null);
  }

  Future<void> _clean({required bool continuation}) async {
    final progress = ref.notifier(workspaceCaptureMaintenanceProvider);
    progress.start(continuation: continuation);
    try {
      final initialWasPublished = _initialReportPublished;
      final store = await ready();
      // ready() may be shared with a source capture. Publish the first actual
      // batch exactly once, even if capture requested initialization first.
      if (!initialWasPublished && _initialReportPublished) return;
      final report = await store.cleanup();
      _log.info('Export cleanup: ${report.toJson()}');
      if (_disposed) return;
      progress.complete(report);
      _continueIfNeeded(report);
    } catch (error) {
      if (!_disposed) {
        if (error is CaptureCleanupInterrupted) progress.complete(error.report);
        progress.fail();
      }
      rethrow;
    }
  }

  void _continueIfNeeded(CaptureCleanupReport report) {
    if (_disposed || !report.budgetReached || _cleanupTimer != null) return;
    _cleanupTimer = Timer(const Duration(milliseconds: 100), () {
      // Keep the timer marker until clean() consumes it as a continuation.
      if (!_disposed) unawaited(clean().catchError((Object _) => _log.warning('Export cleanup continuation retained failures')));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cleanupTimer?.cancel();
    final store = state;
    if (store != null) unawaited(store.close().catchError((Object _) => _log.warning('Export store close failed')));
    super.dispose();
  }
}
