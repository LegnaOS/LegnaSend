import 'dart:convert';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/workspace_capture_store.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:path/path.dart' as p;

String encodeWorkspaceCaptureSelection(List<Map<String, String>> files, {bool documentSnapshot = false}) =>
    jsonEncode(documentSnapshot ? {'mode': 'documentSnapshot', 'files': files} : files);

bool _alwaysCurrent() => true;

class WorkspaceSendCapture {
  final List<CrossFile> files;
  final Future<void> Function() release;
  final bool Function() isCurrent;
  WorkspaceSendCapture(this.files, this.release, {bool Function()? isCurrent}) : isCurrent = isCurrent ?? _alwaysCurrent;
}

/// Only the host chooses the private stage. Remote IDs never become native paths.
Future<WorkspaceSendCapture> captureWorkspaceSources({
  required Future<String> Function(String destination) capture,
  required bool Function() isCurrent,
  required WorkspaceCaptureStore store,
  required int fileCount,
  bool documentSnapshot = false,
}) async {
  final lease = await store.create(fileCount);
  final directory = lease.directory;
  try {
    if (!isCurrent()) throw StateError('Server changed');
    final result = jsonDecode(await capture(directory.path)) as Map<String, dynamic>;
    if (!isCurrent()) throw StateError('Server changed');
    final entries = result['files'] as List;
    if (entries.length != fileCount) throw const FormatException();
    final files = <CrossFile>[];
    final names = <String>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i] as Map;
      if (entry['source'] != 'source-$i' || entry['name'] is! String || entry['size'] is! int || (entry['size'] as int) < 0) {
        throw const FormatException();
      }
      final name = entry['name'] as String;
      if (name.isEmpty || name.startsWith('/') || name.contains('\\') || name.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
        throw const FormatException();
      }
      if (documentSnapshot &&
          (name.contains('/') ||
              name.contains(':') ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
              utf8.encode(name).length > 255 ||
              !names.add(name.toLowerCase()) ||
              entry['sha256'] is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['sha256'] as String))) {
        throw const FormatException('Invalid document snapshot manifest');
      }
      files.add(
        CrossFile(
          name: name,
          fileType: FileType.other,
          size: entry['size'] as int,
          path: p.join(directory.path, 'source-$i'),
          bytes: null,
          thumbnail: null,
          asset: null,
          lastModified: null,
          lastAccessed: null,
        ),
      );
    }
    return WorkspaceSendCapture(List.unmodifiable(files), lease.release, isCurrent: isCurrent);
  } catch (_) {
    try {
      await lease.release();
    } catch (_) {
      // Preserve the original error; an owned retained stage is retried on startup.
    }
    rethrow;
  }
}
