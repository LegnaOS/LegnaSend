import 'dart:io';

import 'package:path/path.dart' as p;

/// Trusted private-bridge metadata, never a peer-supplied filesystem target.
/// A candidate and receipt identity become successful history only after the
/// core has verified the durable cache/final file and reported real success.
class ReceiveRecoveryTarget {
  final String? path;
  final String receiptId;
  final DateTime? completedAt;

  ReceiveRecoveryTarget({required this.path, required this.receiptId, int? completedUnixMs})
    : completedAt = completedUnixMs == null ? null : DateTime.fromMillisecondsSinceEpoch(completedUnixMs, isUtc: true) {
    if (!RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$').hasMatch(receiptId) ||
        (completedUnixMs != null && (completedUnixMs < 0 || path == null))) {
      throw const FormatException('Invalid owned recovery receipt');
    }
  }
}

typedef ReceiveRecoveryLookup = Future<ReceiveRecoveryTarget> Function({required String approvedDirectory, required String requestedName});

/// A second lexical fence after the core's directory-identity/registry lookup.
/// This deliberately does not infer ownership from a filename, scan .ls files,
/// follow symlinks, or treat an existing ordinary file as a recovery record.
String validateRecoveryCandidatePath({
  required String candidate,
  required String expectedDirectory,
  p.Context? pathContext,
  bool? caseInsensitive,
}) {
  final paths = pathContext ?? p.context;
  String key(String value) {
    final result = paths.normalize(paths.absolute(value));
    return (caseInsensitive ?? (Platform.isWindows || Platform.isMacOS || Platform.isIOS)) ? result.toLowerCase() : result;
  }

  if (candidate.contains('\u0000') ||
      !paths.isAbsolute(candidate) ||
      key(paths.dirname(candidate)) != key(expectedDirectory) ||
      key(candidate) == key(expectedDirectory)) {
    throw const FormatException('Recovery target does not match the approved destination');
  }
  return candidate;
}

/// Temporary gallery/cache targets must not gain cross-session recovery merely
/// because they happen to be represented by an ordinary local path.
bool isReceiveCacheDestination(String destination, String cacheDirectory, {p.Context? pathContext, bool? caseInsensitive}) {
  final paths = pathContext ?? p.context;
  String key(String value) {
    final result = paths.normalize(paths.absolute(value));
    return (caseInsensitive ?? (Platform.isWindows || Platform.isMacOS || Platform.isIOS)) ? result.toLowerCase() : result;
  }

  final root = key(cacheDirectory), target = key(destination);
  return root == target || paths.isWithin(root, target);
}
