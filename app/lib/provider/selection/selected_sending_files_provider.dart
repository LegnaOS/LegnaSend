import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/native/android_folder_selection.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/empty_directory_counter.dart';
import 'package:localsend_app/util/native/ios_share_selection_store.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/send_ignore.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/rust/api/metadata.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:share_handler/share_handler.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('SelectedSendingFiles');
const _uuid = Uuid();

/// Manages files selected for sending.
/// Will stay alive even after a session has been completed to send the same files to another device.
final selectedSendingFilesProvider = ReduxProvider<SelectedSendingFilesNotifier, List<CrossFile>>((ref) {
  return SelectedSendingFilesNotifier(shareStore: ref.read(iosShareSelectionStoreProvider));
});

class SelectedSendingFilesNotifier extends ReduxNotifier<List<CrossFile>> {
  final IosShareSelectionStore? shareStore;
  SelectedSendingFilesNotifier({this.shareStore});

  @override
  List<CrossFile> init() => shareStore?.restored ?? [];
}

/// Adds a message.
class AddMessageAction extends ReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> {
  final String message;
  final int? index;

  AddMessageAction({
    required this.message,
    this.index,
  });

  @override
  List<CrossFile> reduce() {
    final List<int> bytes = utf8.encode(message);
    final file = CrossFile(
      name: '${_uuid.v4()}.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );

    return List.unmodifiable(
      [
        ...state,
      ]..insert(index ?? state.length, file),
    );
  }
}

/// Updates a message.
class UpdateMessageAction extends ReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> {
  final String message;
  final int index;

  UpdateMessageAction({
    required this.message,
    required this.index,
  });

  @override
  List<CrossFile> reduce() {
    final previous = state[index];
    final bytes = utf8.encode(message);
    final next = [...state];
    next[index] = previous.copyWith(bytes: bytes, size: bytes.length);
    notifier.shareStore?.retainSelection(next);
    return List.unmodifiable(next);
  }
}

/// Adds a binary file to the list.
/// During the sending process, the file will be read from the memory.
class AddBinaryAction extends ReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> {
  final Uint8List bytes;
  final FileType fileType;
  final String fileName;

  AddBinaryAction({
    required this.bytes,
    required this.fileType,
    required this.fileName,
  });

  @override
  List<CrossFile> reduce() {
    final file = CrossFile(
      name: fileName,
      fileType: fileType,
      size: bytes.length,
      thumbnail: fileType == FileType.image ? bytes : null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );

    return List.unmodifiable([
      ...state,
      file,
    ]);
  }
}

/// Keep the lease through Refena's publication, not only conversion. `after`
/// also runs on before/reduce failure, so failed imports do not pin caches.
abstract class _SourceSelectionAction extends AsyncReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> with GlobalActions {
  SourceCacheLease? _sourceLease;

  @override
  Future<void> before() async {
    _sourceLease = await global.dispatchAsync(AcquireSourceCacheLeaseAction());
  }

  @override
  void after() {
    _sourceLease?.release();
  }
}

/// Adds one or more files to the list.
class AddFilesAction<T> extends _SourceSelectionAction {
  final Iterable<T> files;
  final Future<CrossFile> Function(T) converter;

  AddFilesAction({
    required this.files,
    required this.converter,
  });

  @override
  Future<List<CrossFile>> reduce() async {
    final newFiles = <CrossFile>[];
    for (final file in files) {
      // we do it sequential because there are bugs
      //  https://github.com/fluttercandies/flutter_photo_manager/issues/589

      final crossFile = await converter(file);
      final isAlreadySelect = state.any((element) => element.isSameFile(otherFile: crossFile));
      if (!isAlreadySelect) {
        newFiles.add(crossFile);
      }
    }
    return List.unmodifiable([
      ...state,
      ...newFiles,
    ]);
  }
}

/// Publish an entire system share atomically, with a durable import receipt.
/// Replaying a native manifest after process death never duplicates its text.
class ImportIosShareAction extends _SourceSelectionAction {
  final String batchId;
  final SharedMedia payload;
  final Future<CrossFile> Function(SharedAttachment) converter;

  ImportIosShareAction({required this.batchId, required this.payload, this.converter = CrossFileConverters.convertSharedAttachment});

  @override
  Future<List<CrossFile>> reduce() async {
    final store = notifier.shareStore;
    if (store == null) throw StateError('iOS share recovery storage is not ready');
    if (store.contains(batchId)) return state;
    final files = <CrossFile>[];
    for (final attachment in payload.attachments ?? <SharedAttachment?>[]) {
      if (attachment != null) files.add(await converter(attachment));
    }
    final message = payload.content;
    if (message != null && message.trim().isNotEmpty) {
      final bytes = utf8.encode(message);
      files.add(
        CrossFile(
          name: 'share-$batchId.txt',
          fileType: FileType.text,
          size: bytes.length,
          thumbnail: null,
          asset: null,
          path: null,
          bytes: bytes,
          lastModified: null,
          lastAccessed: null,
        ),
      );
    }
    // Another async import may have finished conversion in the meantime.
    if (store.contains(batchId)) return state;
    store.import(batchId, files);
    return List.unmodifiable([...state, ...files]);
  }
}

/// Adds files inside the directory recursively.
class AddDirectoryAction extends _SourceSelectionAction {
  final String directoryPath;

  AddDirectoryAction(this.directoryPath);

  int emptyDirectories = 0;

  @override
  Future<List<CrossFile>> reduce() async {
    final files = await readDirectoryFiles(directoryPath, onEmptyDirectories: (count) => emptyDirectories = count);
    return List.unmodifiable([...state, ...files.where((file) => !state.any((selected) => selected.isSameFile(otherFile: file)))]);
  }
}

/// Converts a directory without touching the shared selection.
Future<List<CrossFile>> readDirectoryFiles(
  String directoryPath, {
  void Function(int count)? onEmptyDirectories,
  void Function(Iterable<String> paths)? onEmptyDirectoryPaths,
}) async {
  _logger.info('Reading files in $directoryPath');
  final newFiles = <CrossFile>[];
  final directoryName = p.basename(directoryPath);
  final sendIgnore = SendIgnore();
  final emptyDirectories = EmptyDirectoryCounter(directoryPath);
  await for (final entity in Directory(directoryPath).list(recursive: true, followLinks: false)) {
    emptyDirectories.visit(entity);
    if (entity is File) {
      final innerRelative = p.relative(entity.path, from: directoryPath).replaceAll('\\', '/');
      final relative = '$directoryName/$innerRelative';
      if (sendIgnore.isIgnoreFile(p.basename(entity.path))) {
        sendIgnore.loadIgnoreContent(
          parentPath: innerRelative.contains('/') ? p.dirname(innerRelative) : null,
          ignoreContents: await entity.readAsLines(),
        );
        _logger.info('Loaded ignore file: $innerRelative');
        continue;
      } else if (sendIgnore.isIgnored(innerRelative)) {
        _logger.info('Ignored: $innerRelative');
        continue;
      }

      _logger.info('Add file $relative');

      final metadata = await readFileMetadata(path: entity.path);
      final file = CrossFile(
        name: relative,
        fileType: relative.guessFileType(),
        size: entity.lengthSync(),
        thumbnail: null,
        asset: null,
        path: entity.path,
        bytes: null,
        lastModified: metadata?.modified,
        lastAccessed: metadata?.accessed,
      );

      newFiles.add(file);
    }
  }

  onEmptyDirectories?.call(emptyDirectories.count);
  onEmptyDirectoryPaths?.call(emptyDirectories.emptyPaths);
  return newFiles;
}

/// A special [AddDirectoryAction] specifically for Android.
class AddAndroidDirectoryAction extends _SourceSelectionAction {
  final AndroidFolderSelection result;

  AddAndroidDirectoryAction(this.result);

  @override
  Future<List<CrossFile>> reduce() async {
    final newFiles = <CrossFile>[];
    // The platform traversed actual parent-child rows and validated the entire
    // selection before returning. Opaque document IDs are never path components.
    for (final file in result.files) {
      final relative = file.relativePath;
      final crossFile = CrossFile(
        name: relative,
        fileType: file.name.guessFileType(),
        size: file.size,
        thumbnail: null,
        asset: null,
        path: file.uri,
        bytes: null,
        // SAF only provides milliseconds, so there is no point statting in Rust.
        lastModified: file.lastModified?.toUtc().toIso8601String(),
        lastAccessed: null,
      );

      final isAlreadySelect = state.any((element) => element.isSameFile(otherFile: crossFile));
      if (!isAlreadySelect) {
        newFiles.add(crossFile);
      }
    }

    return List.unmodifiable([
      ...state,
      ...newFiles,
    ]);
  }
}

/// Removes a file at the given [index].
class RemoveSelectedFileAction extends ReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> with GlobalActions {
  final int index;

  RemoveSelectedFileAction(this.index);

  @override
  List<CrossFile> reduce() {
    final next = List<CrossFile>.unmodifiable([...state]..removeAt(index));
    notifier.shareStore?.retainSelection(next);
    return next;
  }

  @override
  void after() {
    if (state.isEmpty) {
      global.dispatchAsync(ClearCacheAction()); // ignore: discarded_futures
    }
  }
}

/// Loads the selection from the arguments of the app start.
/// Returns `true` if files were added.
class LoadSelectionFromArgsAction extends AsyncReduxActionWithResult<SelectedSendingFilesNotifier, List<CrossFile>, bool> {
  final List<String> args;

  LoadSelectionFromArgsAction(this.args);

  @override
  Future<(List<CrossFile>, bool)> reduce() async {
    bool filesAdded = false;
    bool nextShare = false;
    bool nextText = false;
    for (final arg in args) {
      if (arg == '--share') {
        nextShare = true;
        continue;
      }
      if (arg == '--text' || arg == '-t') {
        nextText = true;
        continue;
      }
      if (nextShare) {
        nextShare = false;
        final json = jsonDecode(arg);
        final SharedMedia payload = SharedMedia.decode(json);
        final message = payload.content;
        if (message != null && message.trim().isNotEmpty) {
          dispatch(AddMessageAction(message: message));
        }
        await dispatchAsync(
          AddFilesAction(
            files: payload.attachments?.where((a) => a != null).cast<SharedAttachment>() ?? <SharedAttachment>[],
            converter: CrossFileConverters.convertSharedAttachment,
          ),
        );
        filesAdded = true;
        continue;
      }
      if (nextText) {
        nextText = false;
        if (arg.trim().isNotEmpty) {
          dispatch(AddMessageAction(message: arg.trim()));
          filesAdded = true;
        }
        continue;
      }
      if (arg.startsWith('-')) {
        continue;
      }

      final file = File(arg);
      final directory = Directory(arg);

      if (file.existsSync()) {
        await dispatchAsync(
          AddFilesAction(
            files: [file],
            converter: CrossFileConverters.convertFile,
          ),
        );
        filesAdded = true;
      } else if (directory.existsSync()) {
        await dispatchAsync(AddDirectoryAction(arg));
        filesAdded = true;
      }
    }

    return (state, filesAdded);
  }
}

/// Removes all files from the list.
class ClearSelectionAction extends ReduxAction<SelectedSendingFilesNotifier, List<CrossFile>> with GlobalActions {
  @override
  List<CrossFile> reduce() {
    notifier.shareStore?.retainSelection(const []);
    return const [];
  }

  @override
  void after() {
    global.dispatchAsync(ClearCacheAction()); // ignore: discarded_futures
  }
}
