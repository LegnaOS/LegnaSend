import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Installed only on iOS before selection or inbox processing starts.
final iosShareSelectionStoreProvider = Provider<IosShareSelectionStore?>((_) => null);

/// A local selection journal, not a send job. Never initiates network traffic.
/// Writes complete before publishing selection changes or acknowledging imports.
class IosShareSelectionStore {
  final File file;
  Map<String, _Batch> _batches = {};
  static const maxBytes = 16 * 1024 * 1024;

  IosShareSelectionStore(this.file) {
    if (!file.existsSync()) return;
    if (file.lengthSync() > maxBytes) throw const FormatException('Share selection journal exceeds limit');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    if (json['version'] != 1) throw const FormatException('Unknown share selection journal');
    _batches = (json['batches'] as Map<String, dynamic>).map((id, raw) {
      _validateId(id);
      final batch = raw as Map<String, dynamic>;
      final entries = (batch['files'] as List).map((entry) => CrossFileMapper.fromJson(entry as Map<String, dynamic>)).toList();
      for (final entry in entries) {
        _validateFile(entry);
      }
      return MapEntry(id, _Batch(List.unmodifiable(entries), batch['acknowledged'] as bool));
    });
  }

  List<CrossFile> get restored => List.unmodifiable(_batches.values.expand((batch) => batch.files));
  bool contains(String id) => _batches.containsKey(id);

  void import(String id, List<CrossFile> files) {
    _validateId(id);
    if (contains(id)) return;
    final entries = files.map((file) => file.copyWith(thumbnail: null, asset: null)).toList();
    for (final entry in entries) {
      _validateFile(entry);
    }
    _commit({..._batches, id: _Batch(List.unmodifiable(entries), false)});
  }

  /// Keep an empty unacknowledged receipt: a crash after deselection but before
  /// native acknowledgement must not resurrect an explicitly removed share.
  void retainSelection(List<CrossFile> selection) {
    if (_batches.isEmpty) return;
    final retained = {for (final entry in selection) _key(entry): entry};
    final next = <String, _Batch>{};
    for (final entry in _batches.entries) {
      final files = <CrossFile>[];
      for (final previous in entry.value.files) {
        final current = retained[_key(previous)];
        if (current != null) files.add(current.copyWith(thumbnail: null, asset: null));
      }
      if (files.isNotEmpty || !entry.value.acknowledged) next[entry.key] = _Batch(files, entry.value.acknowledged);
    }
    _commit(next);
  }

  void acknowledge(String id) {
    final batch = _batches[id];
    if (batch == null || batch.acknowledged) return;
    final next = {..._batches};
    if (batch.files.isEmpty) {
      next.remove(id);
    } else {
      next[id] = _Batch(batch.files, true);
    }
    _commit(next);
  }

  /// Native inbox exhaustion also reconciles a crash between native removal
  /// and persisting its acknowledgement. Never call after a failed drain.
  void acknowledgeDrained() {
    if (_batches.values.every((batch) => batch.acknowledged)) return;
    _commit({
      for (final entry in _batches.entries)
        if (entry.value.files.isNotEmpty) entry.key: _Batch(entry.value.files, true),
    });
  }

  static String _key(CrossFile entry) => entry.path == null ? 'text:${entry.name}' : 'file:${entry.path}';
  static void _validateId(String id) {
    if (!RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$').hasMatch(id)) {
      throw const FormatException('Invalid share batch ID');
    }
  }

  static void _validateFile(CrossFile file) {
    if (file.asset != null ||
        file.size < 0 ||
        file.name.isEmpty ||
        (file.path == null && (file.bytes == null || file.bytes!.length != file.size)) ||
        (file.path != null && !file.path!.startsWith('/'))) {
      throw const FormatException('Invalid share selection entry');
    }
  }

  void _commit(Map<String, _Batch> next) {
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'batches': next.map(
          (id, batch) => MapEntry(id, {
            'acknowledged': batch.acknowledged,
            'files': batch.files.map((file) => file.toJson()).toList(),
          }),
        ),
      }),
    );
    if (bytes.length > maxBytes) throw const FormatException('Share selection journal exceeds limit');
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.pending');
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      // Same-directory rename replaces atomically on iOS. The old journal stays
      // authoritative until replacement; abandoned .pending is never restored.
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
    _batches = next;
  }
}

class _Batch {
  final List<CrossFile> files;
  final bool acknowledged;
  _Batch(this.files, this.acknowledged);
}
