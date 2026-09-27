import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/refena_flutter.dart';

final webTransferActivityProvider = NotifierProvider<WebTransferActivityNotifier, List<TransferActivity>>((ref) => WebTransferActivityNotifier());

/// Snapshots originate in the Rust HTTP body, not browser timers or progress
/// guesses. Keep response IDs separate from native LocalSend session IDs.
class WebTransferActivityNotifier extends Notifier<List<TransferActivity>> {
  int _generation = -1;
  final Future<String> Function()? loadSnapshot;
  final Future<bool> Function(String id)? cancelRequest;
  WebTransferActivityNotifier({this.loadSnapshot, this.cancelRequest});
  int get generation => _generation;
  int _snapshotRevision = 0;
  int? _confirmedSnapshotGeneration;
  int get snapshotRevision => _snapshotRevision;
  bool get confirmedIdle =>
      _confirmedSnapshotGeneration == _generation &&
      _pendingIds.isEmpty &&
      !state.any((task) => task.active || task.phase == TransferPhase.unconfirmed);
  final _cancels = <(int, String), Future<bool>>{};
  Timer? _pollTimer;
  bool _polling = false, _busy = false, _disposed = false;
  int _pollVersion = 0;
  int _observationFailures = 0;
  bool _stopping = false;
  bool _observationOnly = false;
  final _retiredIds = <String>{};
  final _pendingIds = <String>{};
  int Function()? _listenerGeneration;
  bool Function()? _listenerCurrent;
  String? _lastSnapshot;

  /// Invalidate an in-flight pre-ack read as well as the content dedup cache.
  /// The existing single-flight loop will consume its next fresh read even if
  /// the registry is still empty; no second poller is created.
  void requireFreshSnapshot() {
    _pollVersion++;
    _lastSnapshot = null;
  }

  /// Schedule only after the preceding snapshot was consumed on this isolate.
  /// A paused or busy main isolate therefore queues at most one response.
  void startPolling({required int Function() generation, required bool Function() isCurrent}) {
    _pollTimer?.cancel();
    _pollVersion++;
    _polling = true;
    _stopping = false;
    _observationOnly = false;
    _listenerGeneration = generation;
    _listenerCurrent = isCurrent;
    _lastSnapshot = null;
    _observationFailures = 0;
    if (!_busy) unawaited(_poll());
  }

  Future<void> _poll() async {
    if (_disposed || !_polling || _busy) return;
    if (_listenerCurrent?.call() != true) {
      stopPolling();
      return;
    }
    _busy = true;
    final version = _pollVersion;
    final generation = _listenerGeneration!();
    try {
      final snapshot =
          await (loadSnapshot?.call() ?? ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerWebDownloadSnapshotAction()));
      if (!_disposed && _polling && version == _pollVersion && _listenerCurrent?.call() == true && snapshot != _lastSnapshot) {
        apply(snapshot, generation: generation);
        _observationFailures = 0;
        _lastSnapshot = snapshot;
        if (_observationOnly && _pendingIds.isEmpty) stopPolling();
      }
    } catch (_) {
      // Preserve the last observed bytes on transient observation errors.
      // Stopped publication remains observable; an error is never a terminal.
      if (version == _pollVersion && _observationOnly && _observationFailures < 6) _observationFailures++;
    } finally {
      _busy = false;
      if (!_disposed && _polling) {
        final delay = _observationOnly ? 500 * (1 << _observationFailures) : 500;
        _pollTimer = Timer(Duration(milliseconds: delay), () => unawaited(_poll()));
      }
    }
  }

  void stopPolling() {
    _polling = false;
    _pollVersion++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _listenerCurrent = null;
    _listenerGeneration = null;
  }

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    _cancels.clear();
    _retiredIds.clear();
    _pendingIds.clear();
    super.dispose();
  }

  @override
  List<TransferActivity> init() => [];

  void apply(String snapshot, {required int generation}) {
    if (generation < _generation) return;
    if (snapshot.length > 8 * 1024 * 1024) throw const FormatException('Activity snapshot too large');
    final decoded = jsonDecode(snapshot);
    if (decoded is! List || decoded.length > 256) throw const FormatException('Invalid web activity snapshot');
    final next = <TransferActivity>[];
    final ids = <String>{};
    for (final value in decoded) {
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid response');
      final id = value['id'], name = value['name'], peer = value['peer'], bytes = value['transferred'], total = value['total'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 256 ||
          !ids.add(id) ||
          name is! String ||
          name.length > 8192 ||
          peer is! String ||
          peer.length > 1024 ||
          bytes is! int ||
          bytes < 0 ||
          (total != null && (total is! int || total < 0 || bytes > total))) {
        throw const FormatException('Invalid response accounting');
      }
      final direction = value.containsKey('direction') ? value['direction'] : 'send';
      final workspaceId = value['workspaceId'], workspaceName = value['workspaceName'];
      final operation = value.containsKey('operation') ? value['operation'] : 'download';
      final origin = value.containsKey('origin') ? value['origin'] : 'browser';
      if (!const {'send', 'receive'}.contains(direction) ||
          !const {'download', 'archive', 'upload', 'directory'}.contains(operation) ||
          !const {'browser', 'api'}.contains(origin) ||
          (direction == 'receive') != const {'upload', 'directory'}.contains(operation) ||
          (workspaceId != null && (workspaceId is! String || workspaceId.isEmpty || workspaceId.length > 256)) ||
          (workspaceName != null && (workspaceName is! String || workspaceName.isEmpty || workspaceName.length > 512)) ||
          (workspaceId == null) != (workspaceName == null)) {
        throw const FormatException('Invalid activity metadata');
      }
      final phase = switch (value['phase']) {
        'preparing' => TransferPhase.preparing,
        'transferring' => TransferPhase.transferring,
        'succeeded' => TransferPhase.succeeded,
        'failed' => TransferPhase.failed,
        'canceled' => TransferPhase.canceled,
        _ => throw const FormatException('Invalid response phase'),
      };
      next.add(
        TransferActivity(
          id: id,
          direction: direction == 'receive' ? TransferDirection.receive : TransferDirection.send,
          workspaceId: workspaceId as String?,
          workspaceName: workspaceName as String?,
          operation: operation as String,
          origin: origin as String,
          phase: phase,
          peer: peer,
          kind: TransferActivityKind.webResponse,
          totalKnown: total != null,
          files: [TransferActivityFile(name, total is int ? total : 0, bytes)],
        ),
      );
    }
    // Parsing is atomic: malformed snapshots never partially replace a live list.
    if (generation > _generation) _stopping = false;
    _generation = generation;
    final previous = {for (final task in state) task.id: task};
    // A push can race an older in-flight pull within the same listener. Terminal
    // UUID outcomes are immutable; an older snapshot must not resurrect them.
    for (var index = 0; index < next.length; index++) {
      final old = previous[next[index].id];
      if (old != null && !old.active && old.phase != TransferPhase.unconfirmed) next[index] = old;
    }
    _pendingIds
      ..clear()
      ..addAll(next.where((task) => task.active).map((task) => task.id));
    for (var index = 0; index < next.length; index++) {
      final task = next[index];
      // A pending task may first become visible in the final snapshot or a
      // stopped-only pull. It still belongs to the retired listener, not the
      // next listener that happens to observe this shared history.
      if (_stopping && task.active) _retiredIds.add(task.id);
      if (task.active && (_stopping || _retiredIds.contains(task.id))) next[index] = _unconfirmed(task);
    }
    // A bounded history may already have evicted an unobserved outcome. Keep
    // existing uncertainty explicit, but never retain more than 256 UI records.
    next.addAll(state.where((task) => task.phase == TransferPhase.unconfirmed && !ids.contains(task.id)));
    while (next.length > 256) {
      final completed = next.indexWhere((task) => !task.active && task.phase != TransferPhase.unconfirmed);
      next.removeAt(completed < 0 ? 0 : completed);
    }
    _retiredIds.removeWhere((id) => !next.any((task) => task.id == id && task.phase == TransferPhase.unconfirmed));
    _cancels.removeWhere((key, _) => key.$1 != generation || !next.any((task) => task.id == key.$2 && task.active));
    _confirmedSnapshotGeneration = generation;
    _snapshotRevision++;
    state = List.unmodifiable(next);
  }

  void beginStop({required int generation}) {
    if (generation < _generation) return;
    stopPolling();
    _generation = generation;
    _stopping = true;
    _confirmedSnapshotGeneration = null;
    _retiredIds.addAll(state.where((task) => task.active).map((task) => task.id));
    _cancels.clear();
  }

  void stopped({required int generation, String? finalSnapshot, bool observe = false}) {
    if (generation < _generation) return;
    beginStop(generation: generation);
    var observed = false;
    if (finalSnapshot != null && finalSnapshot.isNotEmpty) {
      try {
        // Convert before merge so a trimmed previously active record is kept
        // explicitly unknown, instead of inventing a cancellation.
        state = [for (final task in state) task.active ? _unconfirmed(task) : task];
        apply(finalSnapshot, generation: generation);
        observed = true;
      } on FormatException {
        // Retain known outcomes and retry observation, never guess a terminal.
      }
    }
    state = [for (final task in state) task.active ? _unconfirmed(task) : task];
    if (observe && (!observed || _pendingIds.isNotEmpty)) {
      _observationOnly = true;
      _polling = true;
      _listenerGeneration = () => generation;
      _listenerCurrent = () => true;
      _lastSnapshot = null;
      if (!_busy) unawaited(_poll());
    }
  }

  TransferActivity _unconfirmed(TransferActivity task) => TransferActivity(
    id: task.id,
    direction: task.direction,
    phase: TransferPhase.unconfirmed,
    peer: task.peer,
    files: task.files,
    kind: task.kind,
    totalKnown: task.totalKnown,
    workspaceId: task.workspaceId,
    workspaceName: task.workspaceName,
    operation: task.operation,
    origin: task.origin,
  );

  Future<bool> cancel(String id, {int? expectedGeneration}) {
    final currentGeneration = _generation;
    if (_disposed ||
        _stopping ||
        expectedGeneration != null && expectedGeneration != currentGeneration ||
        !state.any((task) => task.id == id && task.active)) {
      return Future.value(false);
    }
    final key = (currentGeneration, id);
    return _cancels.putIfAbsent(key, () => Future<bool>.microtask(() => _cancel(id, currentGeneration)));
  }

  Future<bool> _cancel(String id, int generation) async {
    // A stop/replacement may occur after scheduling this microtask but before
    // dispatch. Never send an old command to the next listener.
    if (_disposed || _stopping || generation != _generation || !state.any((task) => task.id == id && task.active)) return false;
    var confirmed = false;
    try {
      final result =
          await (cancelRequest?.call(id) ??
              ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerCancelWebDownloadAction(requestId: id)));
      confirmed = result && !_disposed && !_stopping && generation == _generation;
      return confirmed;
    } finally {
      // Keep successful requests coalesced until the authoritative terminal
      // snapshot arrives. A failed command remains explicitly retryable.
      if (!confirmed) unawaited(_cancels.remove((generation, id)));
    }
  }
}
