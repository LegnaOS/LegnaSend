import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/native_path.dart';
import 'package:path/path.dart' as path;

/// Resolves a default only; callers retain explicit user destinations unchanged.
/// No filesystem writes, environment expansion, URI decoding or silent Home
/// fallback. The file saver creates the chosen directory and reports IO errors.
Future<String> resolveDefaultDownloadDirectory({
  required TargetPlatform platform,
  required Future<String?> Function() systemDownloads,
  required Future<String> Function() applicationDocuments,
  required Map<String, String> environment,
}) async {
  final windows = platform == TargetPlatform.windows;
  final context = windows ? path.windows : path.posix;
  bool valid(String? value) => value != null && isFullyQualifiedNativePath(value, windows: windows);

  // iOS exposes the app's Documents through Files. It does not grant implicit
  // access to the user's Safari/iCloud Downloads directory.
  if (platform == TargetPlatform.iOS) {
    final documents = await applicationDocuments();
    if (valid(documents)) return context.join(documents, 'Downloads');
    throw const FileSystemException('Downloads directory unavailable');
  }

  String? resolved;
  try {
    resolved = await systemDownloads();
  } catch (_) {
    // Only the location query failed. Do not catch filesystem write errors and
    // silently move a download elsewhere after its destination was selected.
  }
  if (valid(resolved)) return resolved!;

  if (platform == TargetPlatform.android) {
    // Never guess /storage/emulated/0: profiles and mounted volumes differ.
    throw const FileSystemException('Downloads directory unavailable');
  }
  final homes = windows
      ? [
          environment['USERPROFILE'],
          if (environment['HOMEDRIVE'] != null && environment['HOMEPATH'] != null) '${environment['HOMEDRIVE']}${environment['HOMEPATH']}',
        ]
      : [environment['HOME']];
  for (final home in homes) {
    if (valid(home)) return context.join(home!, 'Downloads');
  }
  throw const FileSystemException('Downloads directory unavailable');
}
