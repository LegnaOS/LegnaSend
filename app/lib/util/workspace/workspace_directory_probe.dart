import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/native/android_workspace_documents.dart';
import 'package:localsend_app/util/native/ios_workspace_grants.dart';
import 'package:localsend_app/util/native/native_path.dart';

class WorkspaceProbeResult {
  final String? canonicalPath;
  final WorkspaceInvalidReason? invalidReason;
  final String? documentTree;

  String? get verifiedLocator => canonicalPath ?? documentTree;

  const WorkspaceProbeResult.valid(this.canonicalPath) : invalidReason = null, documentTree = null;
  const WorkspaceProbeResult.documents(this.documentTree) : invalidReason = null, canonicalPath = null;
  const WorkspaceProbeResult.invalid(this.invalidReason) : canonicalPath = null, documentTree = null;

  bool get isValid => invalidReason == null;
}

typedef WorkspaceDirectoryProbe = Future<WorkspaceProbeResult> Function(WorkspaceSource source);
typedef WorkspaceWriteProbe = Future<void> Function(WorkspaceSource source);

Future<void> probeWorkspaceWriteAccess(WorkspaceSource source) async {
  if (source.kind == WorkspaceSourceKind.androidTree) {
    await const AndroidWorkspaceDocuments().requireWritable(source.locator);
  }
}

/// Validate the requested entry's capabilities without changing its policy.
/// Read-only trees do not need a write grant; upload intent never silently
/// downgrades when its write grant or provider create capability disappears.
Future<WorkspaceProbeResult> probeWorkspaceEntry(
  DirectoryWorkspace entry, {
  WorkspaceDirectoryProbe readProbe = probeWorkspaceDirectory,
  WorkspaceWriteProbe writeProbe = probeWorkspaceWriteAccess,
}) async {
  final result = await readProbe(entry.source);
  if (!result.isValid || !entry.allowUpload || entry.source.kind != WorkspaceSourceKind.androidTree) return result;
  try {
    await writeProbe(entry.source);
    return result;
  } on TimeoutException {
    return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.timeout);
  } on PlatformException catch (error) {
    return WorkspaceProbeResult.invalid(switch (error.code) {
      'permission' => WorkspaceInvalidReason.permissionDenied,
      'cancelled' => WorkspaceInvalidReason.timeout,
      _ => WorkspaceInvalidReason.ioError,
    });
  } catch (_) {
    return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.ioError);
  }
}

/// Read-only, shallow validation. No recursive walk, write probe or directory
/// creation. Routes must re-check confinement when opening individual files.
Future<WorkspaceProbeResult> probeWorkspaceDirectory(WorkspaceSource source) async {
  if (source.kind == WorkspaceSourceKind.appleBookmark) {
    final id = source.grantId;
    if (id == null) return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.grantUnavailable);
    try {
      // A temporary scope establishes availability only. Publication acquires
      // its own lease before Rust receives this real filesystem path.
      return WorkspaceProbeResult.valid(await const IosWorkspaceGrants().probe(id));
    } catch (_) {
      return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.grantUnavailable);
    }
  }
  if (source.kind == WorkspaceSourceKind.androidTree) {
    try {
      return WorkspaceProbeResult.documents(await const AndroidWorkspaceDocuments().probe(source.locator));
    } on TimeoutException {
      return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.timeout);
    } on PlatformException catch (error) {
      return WorkspaceProbeResult.invalid(switch (error.code) {
        'not_found' => WorkspaceInvalidReason.missing,
        'permission' => WorkspaceInvalidReason.permissionDenied,
        'loading' || 'busy' || 'provider_error' => WorkspaceInvalidReason.ioError,
        'cancelled' => WorkspaceInvalidReason.timeout,
        _ => WorkspaceInvalidReason.grantUnavailable,
      });
    } catch (_) {
      return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.grantUnavailable);
    }
  }
  // Unsupported source kinds must never fall through to filesystem APIs.
  if (source.kind != WorkspaceSourceKind.directory) {
    return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.grantUnavailable);
  }
  if (!isFullyQualifiedNativePath(source.locator, windows: Platform.isWindows)) {
    return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.notDirectory);
  }
  try {
    final directory = Directory(source.locator);
    final canonical = await directory.resolveSymbolicLinks();
    final type = await FileSystemEntity.type(canonical, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.missing);
    if (type != FileSystemEntityType.directory) return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.notDirectory);
    // Reading metadata alone does not establish permission to enumerate.
    await Directory(canonical).list(followLinks: false).take(1).drain<void>();
    return WorkspaceProbeResult.valid(canonical);
  } on FileSystemException catch (error) {
    return WorkspaceProbeResult.invalid(workspacePathError(error.osError?.errorCode, windows: Platform.isWindows));
  }
}

/// POSIX errno values and Win32 error codes occupy different namespaces.
WorkspaceInvalidReason workspacePathError(int? code, {required bool windows}) {
  if (windows) {
    return switch (code) {
      2 || 3 => WorkspaceInvalidReason.missing,
      5 => WorkspaceInvalidReason.permissionDenied,
      267 => WorkspaceInvalidReason.notDirectory,
      _ => WorkspaceInvalidReason.ioError,
    };
  }
  return switch (code) {
    2 => WorkspaceInvalidReason.missing,
    1 || 13 => WorkspaceInvalidReason.permissionDenied,
    20 => WorkspaceInvalidReason.notDirectory,
    _ => WorkspaceInvalidReason.ioError,
  };
}
