import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/ios_share_inbox.dart';
import 'package:localsend_app/util/native/ios_share_selection_store.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:share_handler/share_handler.dart';

const batchId = '12345678-1234-1234-1234-123456789ABC';
CrossFile textFile(String text) => CrossFile(
  name: 'share-$batchId.txt',
  fileType: FileType.text,
  size: utf8.encode(text).length,
  thumbnail: null,
  asset: null,
  path: null,
  bytes: utf8.encode(text),
  lastModified: null,
  lastAccessed: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File journal;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('legnasend-share-selection-');
    journal = File('${root.path}/private/selection.json');
  });
  tearDown(() async => root.delete(recursive: true));

  RefenaContainer container(IosShareSelectionStore store) {
    final value = RefenaContainer(
      overrides: [
        iosShareSelectionStoreProvider.overrideWithValue(store),
        registeredReceiveCacheCleanupProvider.overrideWithValue(() async {}),
        generalTemporaryCacheCleanupProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(value.disposeContainer);
    return value;
  }

  test('journal restores file metadata and text after acknowledgement and fresh container', () async {
    final source = File('${root.path}/中文 100%.txt')..writeAsStringSync('file');
    final file = textFile('file').copyWith(path: source.path, bytes: null, name: '中文 100%.txt');
    final store = IosShareSelectionStore(journal);
    store.import(batchId, [file, textFile('文字')]);
    store.acknowledge(batchId);
    final restored = container(IosShareSelectionStore(journal)).read(selectedSendingFilesProvider);
    expect(restored.map((f) => f.name), ['中文 100%.txt', 'share-$batchId.txt']);
    expect(restored.first.path, source.path);
    expect(utf8.decode(restored.last.bytes!), '文字');
    expect(source.readAsStringSync(), 'file');
  });

  test('partial removal and text editing survive restart without touching source files', () {
    final source = File('${root.path}/source')..writeAsStringSync('file');
    final store = IosShareSelectionStore(journal);
    store.import(batchId, [textFile('file').copyWith(path: source.path, bytes: null), textFile('old')]);
    store.acknowledge(batchId);
    final app = container(store);
    app.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(0));
    app.redux(selectedSendingFilesProvider).dispatch(UpdateMessageAction(message: 'edited 中文', index: 0));
    final reopened = IosShareSelectionStore(journal);
    expect(reopened.restored, hasLength(1));
    expect(utf8.decode(reopened.restored.single.bytes!), 'edited 中文');
    expect(source.existsSync(), true);
  });

  test('clear commits before cleanup and does not restore acknowledged selections', () async {
    final store = IosShareSelectionStore(journal)..import(batchId, [textFile('text')]);
    store.acknowledge(batchId);
    final app = container(store);
    app.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    expect(IosShareSelectionStore(journal).restored, isEmpty);
    expect(IosShareSelectionStore(journal).contains(batchId), false);
    await Future<void>.delayed(Duration.zero);
  });

  test('empty receipt suppresses replay when killed before native acknowledgement', () async {
    final store = IosShareSelectionStore(journal)..import(batchId, [textFile('text')]);
    store.retainSelection([]);
    final reopened = IosShareSelectionStore(journal);
    final app = container(reopened);
    await app
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          ImportIosShareAction(
            batchId: batchId,
            payload: SharedMedia.decode({'content': 'text', 'attachments': []}),
          ),
        );
    expect(app.read(selectedSendingFilesProvider), isEmpty);
    reopened.acknowledge(batchId);
    expect(IosShareSelectionStore(journal).contains(batchId), false);
  });

  test('process death after durable import before native ack replays once including text', () async {
    const channel = MethodChannel('legnasend/ios_share');
    final payload = {'batchId': batchId, 'content': 'shared text', 'attachments': <Object>[]};
    var pending = true, failAck = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'next') return pending ? payload : null;
      if (failAck) throw PlatformException(code: 'interrupted');
      pending = false;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    var store = IosShareSelectionStore(journal);
    var app = container(store);
    Future<void> enqueue(String id, SharedMedia media) => app
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          ImportIosShareAction(batchId: id, payload: media),
        );
    await expectLater(IosShareInbox(onAcknowledged: store.acknowledge).drain(enqueue), throwsA(isA<PlatformException>()));
    store = IosShareSelectionStore(journal);
    app = container(store);
    failAck = false;
    await IosShareInbox(onAcknowledged: store.acknowledge).drain(enqueue);
    expect(app.read(selectedSendingFilesProvider), hasLength(1));
    expect(utf8.decode(app.read(selectedSendingFilesProvider).single.bytes!), 'shared text');
    expect(IosShareSelectionStore(journal).restored, hasLength(1));
  });

  test('all attachments convert before atomic publication, failure leaves text and files untouched', () async {
    final store = IosShareSelectionStore(journal);
    final app = container(store);
    var converted = 0;
    await expectLater(
      app
          .redux(selectedSendingFilesProvider)
          .dispatchAsync(
            ImportIosShareAction(
              batchId: batchId,
              payload: SharedMedia.decode({
                'content': 'text',
                'attachments': [
                  {'path': '/a', 'type': 3},
                  {'path': '/b', 'type': 3},
                ],
              }),
              converter: (attachment) async {
                if (++converted == 2) throw StateError('provider unavailable');
                return textFile('a').copyWith(path: attachment.path, bytes: null);
              },
            ),
          ),
      throwsStateError,
    );
    expect(app.read(selectedSendingFilesProvider), isEmpty);
    expect(journal.existsSync(), false);
  });

  test('overlapping import completions deduplicate by durable batch ID', () async {
    final store = IosShareSelectionStore(journal);
    final app = container(store);
    final gate = Completer<void>();
    ImportIosShareAction action() => ImportIosShareAction(
      batchId: batchId,
      payload: SharedMedia.decode({
        'content': 'text',
        'attachments': [
          {'path': '/a', 'type': 3},
        ],
      }),
      converter: (attachment) async {
        await gate.future;
        return textFile('a').copyWith(path: '/a', bytes: null);
      },
    );
    final a = app.redux(selectedSendingFilesProvider).dispatchAsync(action());
    final b = app.redux(selectedSendingFilesProvider).dispatchAsync(action());
    gate.complete();
    await Future.wait([a, b]);
    expect(app.read(selectedSendingFilesProvider), hasLength(2));
    expect(IosShareSelectionStore(journal).restored, hasLength(2));
  });

  test('failed disk write leaves original state and receipt intact', () {
    final store = IosShareSelectionStore(journal)..import(batchId, [textFile('keep')]);
    final app = container(store);
    Directory('${journal.path}.pending').createSync();
    expect(() => app.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(0)), throwsA(isA<FileSystemException>()));
    expect(app.read(selectedSendingFilesProvider), hasLength(1));
    expect(IosShareSelectionStore(journal).restored, hasLength(1));
  });

  test('truncated pending write does not replace prior committed journal', () {
    IosShareSelectionStore(journal).import(batchId, [textFile('keep')]);
    File('${journal.path}.pending').writeAsStringSync('{');
    expect(IosShareSelectionStore(journal).restored, hasLength(1));
  });

  test('corrupt committed journal fails closed without resetting it', () {
    journal.parent.createSync(recursive: true);
    journal.writeAsStringSync('{broken');
    expect(() => IosShareSelectionStore(journal), throwsFormatException);
    expect(journal.readAsStringSync(), '{broken');
  });

  test('unavailable recovery store does not import or acknowledge into volatile state', () async {
    final app = RefenaContainer();
    addTearDown(app.disposeContainer);
    await expectLater(
      app
          .redux(selectedSendingFilesProvider)
          .dispatchAsync(
            ImportIosShareAction(
              batchId: batchId,
              payload: SharedMedia.decode({'content': 'text', 'attachments': []}),
            ),
          ),
      throwsStateError,
    );
    expect(app.read(selectedSendingFilesProvider), isEmpty);
  });
  test('exhausted native inbox reconciles interrupted acknowledgement without leaking tombstones', () {
    final store = IosShareSelectionStore(journal)..import(batchId, [textFile('text')]);
    store.retainSelection([]);
    final reopened = IosShareSelectionStore(journal);
    expect(reopened.contains(batchId), true);
    reopened.acknowledgeDrained();
    expect(IosShareSelectionStore(journal).contains(batchId), false);
  });

  test('exhausted inbox preserves selected entries while marking receipt acknowledged', () {
    final store = IosShareSelectionStore(journal)..import(batchId, [textFile('text')]);
    store.acknowledgeDrained();
    final reopened = IosShareSelectionStore(journal);
    expect(reopened.restored, hasLength(1));
    reopened.retainSelection([]);
    expect(IosShareSelectionStore(journal).contains(batchId), false);
  });
}
