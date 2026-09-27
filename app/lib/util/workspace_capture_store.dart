import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Private, non-resumable workspace exports. Never scans Downloads or systemTemp.
/// The process lease distinguishes interrupted exports from another live app.
class WorkspaceCaptureStore {
  final Directory root;

  /// Native hosts supply capability-relative deletion; the Dart implementation
  /// is retained only for standalone lease probes and filesystem unit tests.
  final Future<String> Function(String root, String id)? removeStage;
  static const _lockName = '.capture-session.lock';
  static const _format = 'legnasend.workspace-capture.v1';
  static final _id = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$');
  static final _claimed = <String>{};
  final _active = <String, Completer<void>>{};
  RandomAccessFile? _lock;
  Directory? _base;
  StreamIterator<FileSystemEntity>? _scan;
  Future<void>? _initializing;
  bool _closing = false;
  Future<void>? _closeFuture;
  Future<void> _tail = Future<void>.value();
  CaptureCleanupReport lastCleanup = const CaptureCleanupReport();
  CaptureCleanupReport? initialCleanupReport;

  WorkspaceCaptureStore(this.root, {required this.removeStage});

  /// Standalone lease tests only; native application code must inject the core remover.
  WorkspaceCaptureStore.leaseProbe(this.root) : removeStage = null;

  bool get initialized => _lock != null && _initializing == null;

  Future<void> initialize() {
    if (_closing) return Future<void>.error(StateError('Capture store closed'));
    if (_initializing != null) return _initializing!;
    if (_lock != null) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    if (_closing) throw StateError('Capture store closed');
    if (await FileSystemEntity.type(root.path, followLinks: false) == FileSystemEntityType.notFound) await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) throw StateError('Unsafe capture root');
    final base = Directory(await root.resolveSymbolicLinks());
    if (!_claimed.add(base.path)) throw StateError('Capture store busy');
    RandomAccessFile? lock;
    try {
      final file = File(p.join(base.path, _lockName));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) throw StateError('Unsafe capture lock');
      lock = await file.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive); // Non-blocking: never wait on another running app.
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) throw StateError('Unsafe capture lock');
      _base = base;
      _lock = lock;
      lastCleanup = await _cleanup(128);
      initialCleanupReport = lastCleanup;
    } catch (_) {
      await _scan?.cancel();
      _scan = null;
      await lock?.close();
      _claimed.remove(base.path);
      _lock = null;
      _base = null;
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<WorkspaceCaptureLease> create(int count) async {
    if (count < 1 || count > 128) throw ArgumentError.value(count);
    await initialize();
    return _serial(() async {
      if (_closing || _lock == null) throw StateError('Capture store closed');
      final id = const Uuid().v4();
      final directory = Directory(p.join(_base!.path, id));
      await directory.create();
      // No payload writer gets the directory until the ownership record is flushed.
      // Interrupted marker creation leaves at most a small, untrusted empty stage.
      final owner = File(p.join(directory.path, 'owner.json'));
      await owner.create(exclusive: true);
      await owner.writeAsString(jsonEncode({'format': _format, 'id': id, 'count': count}), flush: true);
      _active[id] = Completer<void>();
      return WorkspaceCaptureLease._(directory, () => _release(id));
    });
  }

  Future<void> _release(String id) => _serial(() async {
    final active = _active[id];
    if (active == null) return;
    try {
      final result = await _remove(id);
      lastCleanup = result;
      if (result.failed != 0 || result.retained != 0) throw StateError('Capture cleanup retained files');
    } finally {
      _active.remove(id);
      active.complete();
    }
  });

  Future<CaptureCleanupReport> cleanup({int limit = 128}) async {
    if (limit < 1 || limit > 4096) throw ArgumentError.value(limit);
    await initialize();
    return _serial(() async {
      if (_closing || _lock == null) throw StateError('Capture store closed');
      return lastCleanup = await _cleanup(limit);
    });
  }

  Future<CaptureCleanupReport> _cleanup(int limit) async {
    var report = const CaptureCleanupReport();
    // Retain the paused traversal between batches: unknown/active prefixes must
    // not starve later registered exports. Never accumulate a whole root list.
    final scan = _scan ??= StreamIterator(_base!.list(followLinks: false));
    try {
      while (report.examined < limit) {
        if (!await scan.moveNext()) {
          await scan.cancel();
          _scan = null;
          return report;
        }
        final entity = scan.current;
        final id = p.basename(entity.path);
        if (id == _lockName) continue;
        if (_active.containsKey(id)) {
          report = report.plus(const CaptureCleanupReport(examined: 1, active: 1));
        } else if (entity is! Directory || !_id.hasMatch(id)) {
          report = report.plus(const CaptureCleanupReport(examined: 1, retained: 1));
        } else {
          report = report.plus(await _remove(id));
        }
      }
      // Conservative: the next bounded batch discovers the actual end.
      report = report.plus(const CaptureCleanupReport(budgetReached: true));
      return report;
    } catch (_) {
      // A failed iterator is exhausted: discard it so retry opens a fresh listing.
      try {
        await scan.cancel();
      } catch (_) {}
      _scan = null;
      throw CaptureCleanupInterrupted(report);
    }
  }

  Future<CaptureCleanupReport> _remove(String id) async {
    var removed = 0, bytes = 0;
    try {
      if (removeStage != null) {
        return CaptureCleanupReport.fromJson(jsonDecode(await removeStage!(_base!.path, id)));
      }
      final directory = Directory(p.join(_base!.path, id));
      if (!await _safeParent(directory)) {
        return const CaptureCleanupReport(examined: 1, retained: 1);
      }
      final owner = File(p.join(directory.path, 'owner.json'));
      if (await FileSystemEntity.type(owner.path, followLinks: false) != FileSystemEntityType.file || await owner.length() > 1024) {
        return const CaptureCleanupReport(examined: 1, retained: 1);
      }
      final marker = jsonDecode(await owner.readAsString());
      if (marker is! Map ||
          marker.length != 3 ||
          marker['format'] != _format ||
          marker['id'] != id ||
          marker['count'] is! int ||
          marker['count'] < 1 ||
          marker['count'] > 128) {
        return const CaptureCleanupReport(examined: 1, retained: 1);
      }
      final allowed = {'owner.json', for (var i = 0; i < marker['count']; i++) 'source-$i'};
      final entries = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        // Preflight the entire bounded stage before deleting anything. Unknown
        // files, directories, links and malformed records retain the whole stage.
        if (entity is! File || !allowed.contains(p.basename(entity.path)) || entries.length >= 129) {
          return const CaptureCleanupReport(examined: 1, retained: 1);
        }
        entries.add(entity);
      }
      for (final file in entries) {
        if (p.basename(file.path) == 'owner.json') continue;
        if (!await _safeParent(directory) || await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
          return CaptureCleanupReport(examined: 1, retained: 1, removedFiles: removed, unlinkedBytes: bytes);
        }
        final size = await file.length();
        await file.delete();
        removed++;
        bytes += size;
      }
      // Never recurse; a late foreign entry keeps the stage instead of being swept.
      if (!await _safeParent(directory)) return CaptureCleanupReport(examined: 1, retained: 1, removedFiles: removed, unlinkedBytes: bytes);
      await owner.delete();
      await directory.delete();
      return CaptureCleanupReport(examined: 1, removedStages: 1, removedFiles: removed, unlinkedBytes: bytes);
    } catch (_) {
      return CaptureCleanupReport(examined: 1, failed: 1, removedFiles: removed, unlinkedBytes: bytes);
    }
  }

  // Cooperative application-private storage only. These repeated checks reject
  // observed replacements; path-based Dart I/O is not a hostile same-user race
  // sandbox. Never generalize this cleaner to externally supplied directories.
  Future<bool> _safeParent(Directory directory) async =>
      await FileSystemEntity.type(_base!.path, followLinks: false) == FileSystemEntityType.directory &&
      await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.directory &&
      await directory.resolveSymbolicLinks() == directory.path;

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    try {
      await _initializing;
    } catch (_) {
      return;
    }
    await _tail; // Includes stage admission already in progress before close.
    await Future.wait(_active.values.map((v) => v.future));
    await _tail;
    await _scan?.cancel();
    _scan = null;
    final lock = _lock;
    _lock = null;
    try {
      await lock?.close();
    } finally {
      if (_base != null) _claimed.remove(_base!.path);
    }
  }
}

class WorkspaceCaptureLease {
  final Directory directory;
  final Future<void> Function() _release;
  Future<void>? _released;
  WorkspaceCaptureLease._(this.directory, this._release);
  Future<void> release() => _released ??= _release();
}

class CaptureCleanupReport {
  final int examined, active, retained, failed, removedStages, removedFiles, unlinkedBytes;
  final bool budgetReached;
  const CaptureCleanupReport({
    this.examined = 0,
    this.active = 0,
    this.retained = 0,
    this.failed = 0,
    this.removedStages = 0,
    this.removedFiles = 0,
    this.unlinkedBytes = 0,
    this.budgetReached = false,
  });
  factory CaptureCleanupReport.fromJson(Object? value) {
    const keys = {'examined', 'active', 'retained', 'failed', 'removedStages', 'removedFiles', 'unlinkedBytes', 'budgetReached'};
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(keys).isNotEmpty ||
        value.length != keys.length ||
        value['budgetReached'] is! bool) {
      throw const FormatException('Invalid export cleanup report');
    }
    for (final key in keys.where((key) => key != 'budgetReached')) {
      if (value[key] is! int || (value[key] as int) < 0) throw const FormatException('Invalid export cleanup count');
    }
    return CaptureCleanupReport(
      examined: value['examined'],
      active: value['active'],
      retained: value['retained'],
      failed: value['failed'],
      removedStages: value['removedStages'],
      removedFiles: value['removedFiles'],
      unlinkedBytes: value['unlinkedBytes'],
      budgetReached: value['budgetReached'],
    );
  }
  CaptureCleanupReport plus(CaptureCleanupReport other) => CaptureCleanupReport(
    examined: examined + other.examined,
    active: active + other.active,
    retained: retained + other.retained,
    failed: failed + other.failed,
    removedStages: removedStages + other.removedStages,
    removedFiles: removedFiles + other.removedFiles,
    unlinkedBytes: unlinkedBytes + other.unlinkedBytes,
    budgetReached: budgetReached || other.budgetReached,
  );
  Map<String, Object> toJson() => {
    'examined': examined,
    'active': active,
    'retained': retained,
    'failed': failed,
    'removedStages': removedStages,
    'removedFiles': removedFiles,
    'unlinkedBytes': unlinkedBytes,
    'budgetReached': budgetReached,
  };
}

/// Carries actual deletions made before directory traversal was interrupted.
class CaptureCleanupInterrupted implements Exception {
  final CaptureCleanupReport report;
  const CaptureCleanupInterrupted(this.report);
}
