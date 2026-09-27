import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../mocks.mocks.dart';

ReceiveHistoryEntry _entry(String id) => ReceiveHistoryEntry(
  id: id,
  fileName: '$id.bin',
  fileType: FileType.other,
  path: '/published/$id',
  savedToGallery: false,
  isMessage: false,
  fileSize: 10,
  senderAlias: 'Peer',
  timestamp: DateTime.utc(2026, 1, 1),
);
AddHistoryEntryAction _add(String id, {DateTime? timestamp, bool receipt = false}) {
  final entry = _entry(id);
  return AddHistoryEntryAction(
    entryId: id,
    receiptId: receipt ? id : null,
    fileName: entry.fileName,
    fileType: entry.fileType,
    path: entry.path,
    savedToGallery: false,
    isMessage: false,
    fileSize: 10,
    senderAlias: 'Peer',
    timestamp: timestamp ?? entry.timestamp,
  );
}

class _Storage extends MockPersistenceService {
  List<ReceiveHistoryEntry> disk;
  final gate = Completer<void>(), entered = Completer<void>();
  final snapshots = <List<String>>[];
  int active = 0, peak = 0;
  _Storage([this.disk = const []]);
  @override
  bool isSaveToHistory() => true;
  @override
  List<ReceiveHistoryEntry> getReceiveHistory() => disk;
  @override
  Future<void> setReceiveHistory(List<ReceiveHistoryEntry>? entries, {DateTime? clearedThrough}) async {
    active++;
    if (active > peak) peak = active;
    snapshots.add(entries!.map((entry) => entry.id).toList());
    try {
      if (!entered.isCompleted) {
        entered.complete();
        await gate.future;
      }
      disk = List.of(entries);
    } finally {
      active--;
    }
  }
}

class _FalseStore extends InMemorySharedPreferencesStore {
  _FalseStore() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual PersistenceService rejects a platform false write instead of claiming history saved', () async {
    SharedPreferences.setMockInitialValues({'ls_security_context': '{}', 'ls_version': 999});
    final service = await PersistenceService.initialize(supportsDynamicColors: false);
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(service)]);
    expect(container.read(receiveHistoryProvider), isEmpty);
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _FalseStore();
    try {
      await expectLater(container.redux(receiveHistoryProvider).dispatchAsync(_add('lost', receipt: true)), throwsStateError);
      expect(container.read(receiveHistoryProvider), isEmpty, reason: 'Do not commit the plugin memory cache as persisted provider state');
    } finally {
      SharedPreferencesStorePlatform.instance = previous;
      container.disposeContainer();
    }
  });
  test('reordered older receipt does not displace latest 30 completions', () async {
    final storage = _Storage()..gate.complete();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    final history = container.redux(receiveHistoryProvider);
    for (var index = 1; index <= 30; index++) {
      await history.dispatchAsync(_add('r$index', receipt: true, timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: index))));
    }
    await history.dispatchAsync(_add('older', receipt: true));
    expect(storage.disk.length, 30);
    expect(storage.disk.first.id, 'r30');
    expect(storage.disk.last.id, 'r1');
    container.disposeContainer();
  });
  test('concurrent duplicate receipts persist once and removed receipts never resurrect', () async {
    final storage = _Storage();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    final history = container.redux(receiveHistoryProvider);
    final first = history.dispatchAsync(_add('receipt', receipt: true));
    await storage.entered.future;
    final duplicate = history.dispatchAsync(_add('receipt', receipt: true));
    storage.gate.complete();
    await Future.wait([first, duplicate]);
    expect(storage.snapshots.length, 1);
    await history.dispatchAsync(RemoveHistoryEntryAction('receipt'));
    await history.dispatchAsync(_add('receipt', receipt: true));
    expect(storage.disk, isEmpty);
    container.disposeContainer();
  });
  test('clear blocks late completed receipts but admits completions after the user clear intent', () async {
    final storage = _Storage()..gate.complete();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    final history = container.redux(receiveHistoryProvider);
    await history.dispatchAsync(RemoveAllHistoryEntriesAction());
    await history.dispatchAsync(_add('old-unseen', receipt: true));
    expect(storage.disk, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await history.dispatchAsync(_add('new', receipt: true, timestamp: DateTime.now().toUtc()));
    expect(storage.disk.single.id, 'new');
    container.disposeContainer();
  });
  test('clear intent during blocked add suppresses old late receipts but keeps newer completion', () async {
    final storage = _Storage();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    final history = container.redux(receiveHistoryProvider);
    final first = history.dispatchAsync(_add('first', receipt: true));
    await storage.entered.future;
    final clear = history.dispatchAsync(RemoveAllHistoryEntriesAction());
    final old = history.dispatchAsync(_add('old-late', receipt: true));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final newer = history.dispatchAsync(_add('new', receipt: true, timestamp: DateTime.now().toUtc()));
    storage.gate.complete();
    await Future.wait([first, clear, old, newer]);
    expect(storage.disk.map((e) => e.id), ['new']);
    expect(storage.peak, 1);
    container.disposeContainer();
  });
  test('bounded receipt eviction keeps 30 records and does not resurrect forgotten old IDs', () async {
    final storage = _Storage()..gate.complete();
    final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
    final history = container.redux(receiveHistoryProvider);
    for (var index = 0; index < 520; index++) {
      await history.dispatchAsync(_add('r$index', receipt: true, timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: index))));
    }
    expect(storage.disk.length, 30);
    final writes = storage.snapshots.length;
    await history.dispatchAsync(_add('r0', receipt: true));
    expect(storage.snapshots.length, writes);
    expect(storage.disk.first.id, 'r519');
    container.disposeContainer();
  });
  for (final operation in ['add', 'remove', 'clear']) {
    test('real Refena $operation during a held history write cannot overwrite later user intent', () async {
      final storage = _Storage([_entry('existing')]);
      final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(storage)]);
      final history = container.redux(receiveHistoryProvider);
      final first = history.dispatchAsync(_add('first'));
      await storage.entered.future;
      final second = switch (operation) {
        'add' => history.dispatchAsync(_add('second')),
        'remove' => history.dispatchAsync(RemoveHistoryEntryAction('existing')),
        _ => history.dispatchAsync(RemoveAllHistoryEntriesAction()),
      };
      await Future<void>.delayed(Duration.zero);
      storage.gate.complete();
      await Future.wait([first, second]);
      final expected = switch (operation) {
        'add' => ['second', 'first', 'existing'],
        'remove' => ['first'],
        _ => <String>[],
      };
      expect(storage.peak, 1);
      expect(container.read(receiveHistoryProvider).map((entry) => entry.id), expected);
      expect(storage.disk.map((entry) => entry.id), expected);
      container.disposeContainer();
    });
  }
}
