import 'dart:convert';
import 'dart:io';

import 'package:localsend_isolates/rust/api/server.dart' as native;
import 'package:localsend_isolates/util/android_channel.dart';

/// Local-only picker metadata. Never place a provider URI or raw descriptor in
/// the HTTP request, sample code, history or persisted request JSON.
Future<String> executeApiConsoleWithSource({
  required String request,
  required bool Function() isCurrent,
  required Future<String> Function(String, int?) execute,
  bool? android,
  Future<int> Function(String)? open,
  Future<void> Function(int)? discard,
}) async {
  // Hard-bound input before parsing; only the named large-selection operation
  // may use the larger UTF-8 envelope. Provider-upload metadata stays small.
  const maximumEnvelope = 2 * 1024 * 1024 + 16 * 1024;
  if (request.length > maximumEnvelope) throw const FormatException('Console request too large');
  final bytes = utf8.encode(request).length;
  if (bytes > maximumEnvelope) throw const FormatException('Console request too large');
  final Object? decoded;
  try {
    decoded = jsonDecode(request);
  } catch (_) {
    throw const FormatException('Invalid console request');
  }
  if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid console request');
  final limit = switch (decoded['operation']) {
    'prepareWorkspaceArchive' => maximumEnvelope,
    'sendWorkspaceFiles' => 72 * 1024,
    'getWorkspaceState' || 'listFiles' => 24 * 1024,
    _ => 16 * 1024,
  };
  if (bytes > limit || decoded.containsKey('uploadUri') && bytes > 16 * 1024) {
    throw const FormatException('Console request too large');
  }
  if (!isCurrent()) throw StateError('Server changed before request');
  if (!decoded.containsKey('uploadUri')) return execute(request, null);
  final value = decoded.remove('uploadUri');
  final uri = value is String ? Uri.tryParse(value) : null;
  final size = decoded['uploadSize'];
  if (!(android ?? Platform.isAndroid) ||
      decoded['operation'] != 'uploadFile' ||
      decoded.containsKey('uploadPath') ||
      decoded['parameters'] is! Map ||
      (decoded['parameters'] as Map)['directory'] == 'true' ||
      uri == null ||
      uri.scheme != 'content' ||
      uri.authority.isEmpty ||
      uri.hasFragment ||
      size is! int ||
      size < 0) {
    throw const FormatException('Invalid selected upload source');
  }
  // Serialize before opening: an encoding failure must not strand an owned FD.
  final cleanRequest = jsonEncode(decoded);
  final int fd;
  try {
    fd = await (open ?? (uri) => getFileDescriptorAndroid(uri: uri))(value as String);
  } catch (_) {
    throw StateError('Selected upload source is unavailable');
  }
  if (fd < 0) throw StateError('Invalid upload source descriptor');
  if (!isCurrent()) {
    await (discard ?? (fd) => native.discardDownloadSource(fileDescriptor: fd))(fd);
    throw StateError('Server changed while opening upload source');
  }
  // Rust now owns this descriptor even when validation or the HTTP request fails.
  return execute(cleanRequest, fd);
}
