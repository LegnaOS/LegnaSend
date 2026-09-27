import 'dart:io';

import 'package:gal/gal.dart';
import 'package:localsend_isolates/rust/api/filename.dart' as rust_filename;
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:localsend_isolates/src/task/server/saf_receive_attempt.dart';
import 'package:localsend_isolates/util/android_channel.dart' as android_channel;
import 'package:localsend_isolates/util/content_uri_helper.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('FileSaver');

/// Where an incoming file should be written to.
/// The actual writing is done by the Rust server which receives either a
/// plain file [path] or a writable [fileDescriptor] (Android SAF).
class FileSaveTarget {
  /// The path to write the file to. `null` when [fileDescriptor] is used.
  final String? path;

  /// A writable file descriptor (Android SAF). `null` when [path] is used.
  final int? fileDescriptor;

  /// The path or content URI of the destination, used for the history
  /// and to locate the file after it has been written.
  final String _displayPath;
  final SafReceiveAttempt? saf;
  final ReceiveRecoveryTarget? recovery;
  String get displayPath => saf?.publishedUri ?? _displayPath;

  FileSaveTarget({
    required this.path,
    required this.fileDescriptor,
    required String displayPath,
    this.saf,
    this.recovery,
  }) : _displayPath = displayPath;
}

/// Prepares the destination for an incoming file with [fileName].
///
/// When [saveToGallery] is true, the file is first written to the
/// [cacheDirectory]; call [saveCachedFileToGallery] after the file has been
/// written.
///
/// On Android, destinations that cannot be written directly (SAF content URIs
/// and SD cards) are created via the Storage Access Framework and a writable
/// file descriptor is returned instead of a path.
Future<FileSaveTarget> prepareFileSaveTarget({
  required String destinationDirectory,
  required String cacheDirectory,
  required String fileName,
  required bool saveToGallery,
  required bool isImage,
  required Set<String> createdDirectories,
  ReceivePathReservations? reservations,
  int? androidSdkInt,
  String? receiveSessionId,
  String? receiveFileId,
  ReceiveRecoveryLookup? recoveryLookup,
  String? previousPath,
  bool Function()? isActive,
}) async {
  ensureReceiveTargetActive(isActive);
  final parentDirectory = saveToGallery ? cacheDirectory : destinationDirectory;
  final eligibleRecovery =
      !saveToGallery &&
      !destinationDirectory.startsWith('content://') &&
      !isReceiveCacheDestination(destinationDirectory, cacheDirectory) &&
      (androidSdkInt == null || getSdCardPath(destinationDirectory) == null);
  ReceiveRecoveryTarget? recovery;

  final (destinationPath, documentUri, finalName) = await digestFilePathAndPrepareDirectory(
    parentDirectory: parentDirectory,
    fileName: fileName,
    createdDirectories: createdDirectories,
    reservations: reservations,
    reservationOwner: receiveFileId,
    recoveryLookup: eligibleRecovery ? recoveryLookup : null,
    previousPath: eligibleRecovery ? previousPath : null,
    onRecoveryTarget: (value) => recovery = value,
    isActive: isActive,
  );
  ensureReceiveTargetActive(isActive);

  // When saveToGallery is enabled, the cache directory is used so SAF is not needed
  if (!saveToGallery && androidSdkInt != null) {
    String? parentUri;
    if (documentUri != null || destinationPath.startsWith('content://')) {
      parentUri = documentUri ?? destinationPath;
    } else {
      final sdCardPath = getSdCardPath(destinationPath);
      if (sdCardPath != null) {
        final uriString = ContentUriHelper.encodeTreeUri(sdCardPath.path.parentPath());
        parentUri = 'content://com.android.externalstorage.documents/tree/${sdCardPath.sdCardId}:$uriString';
      }
    }

    if (parentUri != null) {
      if (parentDirectory.startsWith('content://') && receiveSessionId != null && receiveFileId != null) {
        final attempt = await prepareSafReceiveAttempt(
          treeUri: parentDirectory,
          parentUri: parentUri,
          fileName: finalName,
          sessionId: receiveSessionId,
          fileId: receiveFileId,
        );
        return FileSaveTarget(path: null, fileDescriptor: null, displayPath: attempt.preparation.stagingUri, saf: attempt);
      }
      _logger.info('Using SAF to save file to $parentUri as $finalName');
      final createdFile = await android_channel.createFileAndroid(
        parentUri: parentUri,
        fileName: finalName,
        mimeType: lookupMimeType(finalName) ?? (isImage ? 'image/*' : '*/*'),
      );
      return FileSaveTarget(
        path: null,
        fileDescriptor: createdFile.fileDescriptor,
        displayPath: createdFile.uri,
      );
    }
  }

  return FileSaveTarget(
    path: destinationPath,
    fileDescriptor: null,
    displayPath: destinationPath,
    recovery: recovery,
  );
}

/// Prepares [target] for another attempt at the same file, e.g. after the
/// previous attempt was rejected because of a checksum mismatch.
///
/// The chosen destination is kept instead of allocating another numbered name.
/// Cached path/provider retries use a fresh transaction. Legacy descriptor
/// retries rewrite their already-created document.
Future<FileSaveTarget> reopenFileSaveTarget(FileSaveTarget target) async {
  final previous = target.saf;
  if (previous != null) {
    final attempt = await prepareSafReceiveAttempt(
      treeUri: previous.treeUri,
      parentUri: previous.parentUri,
      fileName: previous.fileName,
      sessionId: previous.sessionId,
      fileId: previous.fileId,
    );
    return FileSaveTarget(path: null, fileDescriptor: null, displayPath: attempt.preparation.stagingUri, saf: attempt);
  }
  final path = target.path;
  if (path != null) {
    // The server uses a fresh owned .ls transaction and no-overwrite publication.
    return target;
  }

  // The descriptor of the previous attempt was consumed by it, so the SAF
  // document has to be opened again.
  _logger.info('Reopening ${target.displayPath}');
  return FileSaveTarget(
    path: null,
    fileDescriptor: await android_channel.openFileForWritingAndroid(uri: target.displayPath),
    displayPath: target.displayPath,
  );
}

/// Moves a file that has been written to the cache directory into the
/// OS gallery (Photos/Videos).
///
/// If the gallery rejects the file (unsupported format, missing permission,
/// not enough space, ...), the cached file is moved to [destinationDirectory]
/// as fallback. At this point the file is already fully received and the
/// sender was already told success, so failing the transfer would lose it.
///
/// Returns (savedToGallery, filePath):
/// - savedToGallery: true if saved to gallery, false if saved to directory
/// - filePath: absolute path to file (null when saved to gallery)
Future<(bool, String?)> saveCachedFileToGallery({
  required String cachedPath,
  required String destinationDirectory,
  required String fileName,
  required bool isImage,
  required Set<String> createdDirectories,
}) async {
  try {
    isImage ? await Gal.putImage(cachedPath) : await Gal.putVideo(cachedPath);
  } on GalException catch (e) {
    _logger.warning('Could not save to gallery (${e.type.name}), moving to destination directory', e);

    final (fallbackPath, _, _) = await digestFilePathAndPrepareDirectory(
      parentDirectory: destinationDirectory,
      fileName: fileName,
      createdDirectories: createdDirectories,
    );

    _logger.info('Moving file from $cachedPath to $fallbackPath');
    await File(cachedPath).rename(fallbackPath);
    return (false, fallbackPath);
  }

  try {
    await File(cachedPath).delete();
  } catch (e) {
    _logger.warning('Could not delete cached file after saving to gallery', e);
  }
  return (true, null);
}

/// Turns the peer-supplied [fileName] into a relative name that stays inside
/// the destination directory.
///
/// Protocol v2 lets a name carry directory components, for folder transfers.
/// The peer chooses them, so they get the same treatment as the base name:
/// `..` and absolute names are refused outright rather than rewritten, since a
/// name that tries to leave the destination is not a name to guess at, and
/// every remaining component is sanitized. Without that, only the base name
/// was checked and a directory could still be named `con`, end in a dot or
/// carry control characters.
///
/// Throws `'Path traversal detected'` when the name tries to leave the
/// destination.
List<String> sanitizeRelativeName(String fileName) {
  final parts = p.split(fileName);

  final components = <String>[];
  for (final part in parts) {
    // `p.split` keeps the root of an absolute name ('/', 'C:\\', ...) as the
    // first component, so this catches absolute names as well.
    if (part == '..' || p.rootPrefix(part).isNotEmpty) {
      throw 'Path traversal detected';
    }
    // A '.' component (and the empty ones `p.split` can produce) addresses the
    // directory it is in, so it simply drops out.
    if (part == '.' || part.isEmpty) {
      continue;
    }
    components.add(rust_filename.sanitizeFileName(name: part));
  }

  // Everything collapsed, e.g. the name was empty or just '.'.
  if (components.isEmpty) {
    components.add(rust_filename.sanitizeFileName(name: ''));
  }

  return components;
}

/// If there is a file with the same name, then it appends a number to its file name
Future<(String, String?, String)> digestFilePathAndPrepareDirectory({
  required String parentDirectory,
  required String fileName,
  required Set<String> createdDirectories,
  ReceivePathReservations? reservations,
  String? reservationOwner,
  ReceiveRecoveryLookup? recoveryLookup,
  String? previousPath,
  void Function(ReceiveRecoveryTarget)? onRecoveryTarget,
  bool Function()? isActive,
}) async {
  ensureReceiveTargetActive(isActive);
  final components = sanitizeRelativeName(fileName);

  if (parentDirectory.startsWith('content://')) {
    // Provider IDs may be UUIDs or database keys, not relative filesystem paths.
    // Fail the current request on revoked/offline access; never guess a URI or
    // fall back to another destination. Do not cache grants across attempts.
    final documentUri = await android_channel.resolveReceiveDirectoryAndroid(
      treeUri: parentDirectory,
      components: components.take(components.length - 1).toList(),
    );
    ensureReceiveTargetActive(isActive);
    // Only createFile's actual returned URI becomes the final history location.
    return (documentUri, documentUri, components.last);
  }

  final actualFileName = components.last;
  final dir = p.joinAll([parentDirectory, ...components.take(components.length - 1)]);

  if (components.length > 1) {
    // Second gate: the components above cannot escape on their own, but the
    // resulting directory is what is about to be created.
    if (!p.isWithin(parentDirectory, dir)) {
      throw 'Path traversal detected';
    }
  }

  // The selected root is trusted (it may intentionally be a user-selected
  // symlink), but peer-supplied descendants must never follow links. Walk one
  // component at a time so an existing link is rejected before creating deeper
  // folders outside the destination. IO errors propagate to the current upload.
  final names = reservations ?? ReceivePathReservations();
  await names.prepareDirectory(
    path: parentDirectory,
    isActive: isActive,
    prepare: (hasActiveOwner) async {
      ensureReceiveTargetActive(hasActiveOwner);
      await Directory(parentDirectory).create(recursive: true);
    },
  );
  ensureReceiveTargetActive(isActive);
  var current = parentDirectory;
  for (final component in components.take(components.length - 1)) {
    current = p.join(current, component);
    final directory = current;
    ensureReceiveTargetActive(isActive);
    await names.prepareDirectory(
      path: directory,
      isActive: isActive,
      prepare: (hasActiveOwner) async {
        var type = await FileSystemEntity.type(directory, followLinks: false);
        ensureReceiveTargetActive(hasActiveOwner);
        if (type == FileSystemEntityType.notFound) {
          await Directory(directory).create();
          ensureReceiveTargetActive(hasActiveOwner);
          type = await FileSystemEntity.type(directory, followLinks: false);
          ensureReceiveTargetActive(hasActiveOwner);
        }
        if (type != FileSystemEntityType.directory) {
          throw FileSystemException('Destination component is not a regular directory', directory);
        }
      },
    );
    ensureReceiveTargetActive(isActive);
  }

  if (recoveryLookup != null) {
    if (reservationOwner == null) throw StateError('Missing approved recovery file owner');
    final recovery = await recoveryLookup(approvedDirectory: parentDirectory, requestedName: components.join('/'));
    ensureReceiveTargetActive(isActive);
    onRecoveryTarget?.call(recovery);
    final candidate = recovery.path ?? previousPath;
    if (candidate != null) {
      final checked = validateRecoveryCandidatePath(candidate: candidate, expectedDirectory: dir);
      names.reserveRecovery(path: checked, owner: reservationOwner, isActive: isActive);
      return (checked, null, p.basename(checked));
    }
  }
  final destinationPath = await names.allocate(directory: dir, fileName: actualFileName, owner: reservationOwner, isActive: isActive);
  return (destinationPath, null, p.basename(destinationPath));
}

final _sdCardPathRegex = RegExp(r'^/storage/([A-Fa-f0-9]{4}-[A-Fa-f0-9]{4})/(.*)$');

class SdCardPath {
  final String sdCardId;
  final String path;

  SdCardPath(this.sdCardId, this.path);
}

/// Checks if the [path] is on the SD card and returns the SD card path.
/// Returns `null` if the [path] is not on the SD card.
/// Only works on Android.
SdCardPath? getSdCardPath(String path) {
  final match = _sdCardPathRegex.firstMatch(path);
  if (match == null) {
    return null;
  }
  return SdCardPath(match.group(1)!, match.group(2)!);
}
