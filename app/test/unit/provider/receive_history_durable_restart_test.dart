import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

AddHistoryEntryAction receipt(String id, DateTime completed) => AddHistoryEntryAction(
  entryId: 'native-durable:$id',
  receiptId: 'native-durable:$id',
  fileName: 'file.bin',
  fileType: FileType.other,
  path: '/approved/file.bin',
  savedToGallery: false,
  isMessage: false,
  fileSize: 1048576,
  senderAlias: 'Peer',
  timestamp: completed,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'ls_security_context': '{}', 'ls_version': 999}));
  Future<(RefenaContainer, PersistenceService)> open() async {
    final persistence = await PersistenceService.initialize(supportsDynamicColors: false);
    return (RefenaContainer(overrides: [persistenceProvider.overrideWithValue(persistence)]), persistence);
  }

  test('owned publication receipt deduplicates across new sessions and reconstructed persistence/provider', () async {
    final completed = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final (first, _) = await open();
    await first.redux(receiveHistoryProvider).dispatchAsync(receipt('published', completed));
    first.disposeContainer();
    final (second, _) = await open();
    addTearDown(second.disposeContainer);
    await second.redux(receiveHistoryProvider).dispatchAsync(receipt('published', completed));
    expect(second.read(receiveHistoryProvider).length, 1);
  });
  test('cleared or individually removed durable receipt never resurrects after provider restart', () async {
    final completed = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final (first, _) = await open();
    final history = first.redux(receiveHistoryProvider);
    await history.dispatchAsync(receipt('one', completed));
    await history.dispatchAsync(receipt('two', completed));
    await history.dispatchAsync(RemoveHistoryEntryAction('native-durable:one'));
    first.disposeContainer();
    final (second, _) = await open();
    await second.redux(receiveHistoryProvider).dispatchAsync(receipt('one', completed));
    expect(second.read(receiveHistoryProvider).map((entry) => entry.id), ['native-durable:two']);
    await second.redux(receiveHistoryProvider).dispatchAsync(RemoveAllHistoryEntriesAction());
    second.disposeContainer();
    final (third, service) = await open();
    addTearDown(third.disposeContainer);
    await third.redux(receiveHistoryProvider).dispatchAsync(receipt('two', completed));
    await third.redux(receiveHistoryProvider).dispatchAsync(receipt('late-unseen', completed));
    expect(third.read(receiveHistoryProvider), isEmpty);
    expect(service.getReceiveHistorySuppression()!['clearedThrough'], isA<int>());
    await third.redux(receiveHistoryProvider).dispatchAsync(receipt('new', DateTime.now().toUtc().add(const Duration(seconds: 1))));
    expect(third.read(receiveHistoryProvider).single.id, 'native-durable:new');
  });
  test('clear cutoff uses user intent, not later storage time', () async {
    final (initial, service) = await open();
    addTearDown(initial.disposeContainer);
    final requested = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
    await service.setReceiveHistory([], clearedThrough: requested);
    final (container, _) = await open();
    addTearDown(container.disposeContainer);
    await container.redux(receiveHistoryProvider).dispatchAsync(receipt('after-intent', requested.add(const Duration(seconds: 1))));
    expect(container.read(receiveHistoryProvider).single.id, 'native-durable:after-intent');
  });
  test('legacy list migrates without data loss and old duplicate storage is removed after atomic update', () async {
    final (initial, service) = await open();
    final completed = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await initial.redux(receiveHistoryProvider).dispatchAsync(receipt('legacy', completed));
    final old = service.getReceiveHistory().map((entry) => jsonEncode(entry.toJson())).toList();
    initial.disposeContainer();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('legnasend_receive_history_v2');
    await prefs.setStringList('ls_receive_history', old);
    final (migrated, migratedService) = await open();
    addTearDown(migrated.disposeContainer);
    expect(migrated.read(receiveHistoryProvider).single.id, 'native-durable:legacy');
    await migrated.redux(receiveHistoryProvider).dispatchAsync(RemoveAllHistoryEntriesAction());
    expect(migratedService.getReceiveHistory(), isEmpty);
    expect(prefs.containsKey('ls_receive_history'), isFalse);
    expect(prefs.getString('legnasend_receive_history_v2'), isNotNull);
  });
}
