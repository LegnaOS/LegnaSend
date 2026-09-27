import 'dart:async';

import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _maxHistoryEntries = 30;
const _maxReceiptIds = 512;

/// This provider stores the history of received files.
/// It automatically saves the history to the device's storage.
final receiveHistoryProvider = ReduxProvider<ReceiveHistoryService, List<ReceiveHistoryEntry>>((ref) {
  return ReceiveHistoryService(ref.read(persistenceProvider));
});

class ReceiveHistoryService extends ReduxNotifier<List<ReceiveHistoryEntry>> {
  final PersistenceService _persistence;
  Future<void> _tail = Future<void>.value();
  final _receipts = <String, DateTime>{};
  DateTime? _receiptFloor, _clearedThrough;

  bool _seen(String id, DateTime timestamp) =>
      _receipts.containsKey(id) ||
      state.any((entry) => entry.id == id) ||
      (_receiptFloor != null && !timestamp.isAfter(_receiptFloor!)) ||
      (_clearedThrough != null && !timestamp.isAfter(_clearedThrough!));

  void _remember(String id, DateTime timestamp) {
    _receipts.putIfAbsent(id, () => timestamp.toUtc());
    while (_receipts.length > _maxReceiptIds) {
      final oldest = _receipts.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b);
      final evicted = _receipts.remove(oldest.key)!;
      if (_receiptFloor == null || evicted.isAfter(_receiptFloor!)) _receiptFloor = evicted;
    }
  }

  ReceiveHistoryService(this._persistence);

  @override
  List<ReceiveHistoryEntry> init() {
    final suppression = _persistence.getReceiveHistorySuppression();
    if (suppression != null) {
      final deleted = suppression['deleted'] as Map? ?? const {};
      for (final entry in deleted.entries) {
        if (entry.key is String && entry.value is int) {
          _remember(entry.key as String, DateTime.fromMillisecondsSinceEpoch(entry.value as int, isUtc: true));
        }
      }
      final floor = suppression['floor'];
      if (floor is int) _receiptFloor = DateTime.fromMillisecondsSinceEpoch(floor, isUtc: true);
      final clear = suppression['clearedThrough'];
      if (clear is int) _clearedThrough = DateTime.fromMillisecondsSinceEpoch(clear, isUtc: true);
    }
    return _persistence.getReceiveHistory();
  }
}

/// Serialize through Refena's final state commit, not merely through the disk
/// future: another reducer must not calculate from a not-yet-committed snapshot.
abstract class _HistoryAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  Completer<void>? _release;
  @override
  Future<void> before() async {
    final previous = notifier._tail;
    _release = Completer<void>();
    notifier._tail = _release!.future;
    await previous;
  }

  @override
  void after() => _release?.complete();
}

/// Adds a history entry.
class AddHistoryEntryAction extends _HistoryAction {
  final String entryId;

  /// Internal successful-publication identity, absent for legacy/message callers.
  final String? receiptId;
  final String fileName;
  final FileType fileType;
  final String? path;
  final bool savedToGallery;
  final bool isMessage;
  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;

  AddHistoryEntryAction({
    required this.entryId,
    this.receiptId,
    required this.fileName,
    required this.fileType,
    required this.path,
    required this.savedToGallery,
    required this.isMessage,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
  });

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    final receipt = receiptId;
    if (receipt != null && notifier._seen(receipt, timestamp)) return state;
    if (!notifier._persistence.isSaveToHistory()) {
      if (receipt != null) notifier._remember(receipt, timestamp);
      return state;
    }

    final candidates = [
      ReceiveHistoryEntry(
        id: entryId,
        fileName: fileName,
        fileType: fileType,
        path: path,
        savedToGallery: savedToGallery,
        isMessage: isMessage,
        fileSize: fileSize,
        senderAlias: senderAlias,
        timestamp: timestamp,
      ),
      ...state,
    ];
    if (receipt != null) candidates.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final updated = candidates.take(_maxHistoryEntries).toList();
    await notifier._persistence.setReceiveHistory(updated);
    if (receipt != null) notifier._remember(receipt, timestamp);
    return updated;
  }
}

/// Removes a history entry.
class RemoveHistoryEntryAction extends _HistoryAction {
  final String entryId;

  RemoveHistoryEntryAction(this.entryId);

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    final index = state.indexWhere((e) => e.id == entryId);
    if (index == -1) return state;
    final removed = state[index];
    final updated = [...state]..removeAt(index);
    await notifier._persistence.setReceiveHistory(updated);
    notifier._remember(removed.id, removed.timestamp);
    return updated;
  }
}

/// Removes all history entries.
class RemoveAllHistoryEntriesAction extends _HistoryAction {
  late DateTime _requestedAt;
  @override
  Future<void> before() {
    // New completions after this user intent remain eligible, even if storage
    // takes a long time. Old completed receipts arriving late must stay cleared.
    _requestedAt = DateTime.now().toUtc();
    return super.before();
  }

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    await notifier._persistence.setReceiveHistory([], clearedThrough: _requestedAt);
    for (final entry in state) {
      notifier._remember(entry.id, entry.timestamp);
    }
    if (notifier._clearedThrough == null || _requestedAt.isAfter(notifier._clearedThrough!)) notifier._clearedThrough = _requestedAt;
    return [];
  }
}
