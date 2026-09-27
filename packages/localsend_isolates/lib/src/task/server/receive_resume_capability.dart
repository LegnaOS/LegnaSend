import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';
import 'package:path/path.dart' as p;

/// Only persistent ordinary paths use the optional same-session resume cache.
/// SAF is negotiated separately after a real descriptor-pair probe; legacy
/// SD-card targets and gallery post-processing keep whole-file behavior. A missing DTO checksum does not disable negotiation:
/// the sender supplies a mandatory strong full-file hash in the optional open.
List<String> resumableReceiveFileIds({
  required String destinationDirectory,
  required bool saveToGallery,
  required int? androidSdkInt,
  required Iterable<String> acceptedIds,
  required Map<String, int> sizes,
}) {
  if (saveToGallery ||
      !p.isAbsolute(destinationDirectory) ||
      destinationDirectory.startsWith('content://') ||
      (androidSdkInt != null && getSdCardPath(destinationDirectory) != null)) {
    return const [];
  }
  return [
    for (final id in acceptedIds)
      if ((sizes[id] ?? -1) >= 1024 * 1024) id,
  ];
}

/// Cross-session recovery excludes temporary caches in addition to the ordinary
/// same-session capability gates. The core also requires its owned registry.
List<String> durableReceiveFileIds({
  required String destinationDirectory,
  required String cacheDirectory,
  required bool saveToGallery,
  required int? androidSdkInt,
  required Iterable<String> acceptedIds,
  required Map<String, int> sizes,
}) {
  if (isReceiveCacheDestination(destinationDirectory, cacheDirectory)) return const [];
  return resumableReceiveFileIds(
    destinationDirectory: destinationDirectory,
    saveToGallery: saveToGallery,
    androidSdkInt: androidSdkInt,
    acceptedIds: acceptedIds,
    sizes: sizes,
  );
}

/// A bounded per-approval probe cache. Do not cache across listener lifetimes or
/// different descendant parents/mounts. Lack of capability only disables durable
/// recovery; the original and same-session paths remain available.
Future<List<String>> probeDurableReceiveFileIds({
  required String approvedDirectory,
  required Iterable<String> candidates,
  required Map<String, String> approvedNames,
  required Future<bool> Function({required String approvedDirectory, required String requestedName}) probe,
  required bool Function() isActive,
  int maxParents = 64,
}) async {
  final parents = <String, bool>{};
  final accepted = <String>[];
  for (final id in candidates) {
    if (!isActive()) return const [];
    final name = approvedNames[id];
    if (name == null) continue;
    final List<String> components;
    try {
      components = sanitizeRelativeName(name);
    } catch (_) {
      continue;
    }
    final parent = components.take(components.length - 1).join('/');
    var supported = parents[parent];
    if (supported == null) {
      if (parents.length >= maxParents) continue;
      try {
        supported = await probe(approvedDirectory: approvedDirectory, requestedName: components.join('/'));
      } catch (_) {
        supported = false;
      }
      if (!isActive()) return const [];
      parents[parent] = supported;
    }
    if (supported) accepted.add(id);
  }
  return accepted;
}

/// SAF same-session recovery is advertised only after preparing disposable
/// documents in each actual approved relative parent. Never reuse these targets,
/// directory bookkeeping or path reservations for the real upload.
Future<List<String>> probeSafResumableReceiveFileIds({
  required String destinationDirectory,
  required String cacheDirectory,
  required String sessionId,
  required bool saveToGallery,
  required int? androidSdkInt,
  required Iterable<String> acceptedIds,
  required Map<String, int> sizes,
  required Map<String, String> approvedNames,
  required bool Function() isActive,
  required Future<bool> Function({required int cacheDescriptor, required int stagingDescriptor}) probe,
  Future<FileSaveTarget> Function({required String fileId, required String fileName, required Set<String> createdDirectories})? prepare,
  int maxParents = 64,
}) async {
  if (saveToGallery || androidSdkInt == null || !destinationDirectory.startsWith('content://') || !isActive()) return const [];
  final parents = <String, bool>{};
  final accepted = <String>[];
  final createdDirectories = <String>{};
  final parentLimit = maxParents.clamp(0, 64);
  for (final id in acceptedIds) {
    if (!isActive()) return const [];
    if ((sizes[id] ?? -1) < 1024 * 1024) continue;
    final name = approvedNames[id];
    if (name == null) continue;
    final List<String> components;
    try {
      components = sanitizeRelativeName(name);
    } catch (_) {
      continue;
    }
    final parent = components.take(components.length - 1).join('/');
    var supported = parents[parent];
    if (supported == null) {
      if (parents.length >= parentLimit) continue;
      try {
        final target = prepare != null
            ? await prepare(fileId: id, fileName: components.join('/'), createdDirectories: createdDirectories)
            : await prepareFileSaveTarget(
                destinationDirectory: destinationDirectory,
                cacheDirectory: cacheDirectory,
                fileName: components.join('/'),
                saveToGallery: false,
                isImage: false,
                createdDirectories: createdDirectories,
                androidSdkInt: androidSdkInt,
                receiveSessionId: sessionId,
                receiveFileId: id,
                isActive: isActive,
              );
        // The SAF branch above always returns a cached pair. An unexpected
        // target provides no authority to advertise this optional capability.
        final attempt = target.saf;
        if (attempt == null) {
          final descriptor = target.fileDescriptor;
          if (descriptor != null) await discardSafDescriptors([descriptor]);
          supported = false;
        } else {
          supported = await attempt.probeDescriptors(probe: probe, isActive: isActive);
        }
      } catch (_) {
        supported = false;
      }
      if (!isActive()) return const [];
      parents[parent] = supported;
    }
    if (supported) accepted.add(id);
  }
  return isActive() ? accepted : const [];
}
