import 'dart:async';
import 'dart:io';

import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:path/path.dart' as p;

/// Session-local names chosen before .ls attempts publish their final files.
/// This is not a filesystem lock: the Rust no-overwrite publication is still
/// authoritative if another process creates the chosen name later.
class ReceivePathReservations {
  final bool caseInsensitive;
  final Future<FileSystemEntityType> Function(String) _entryType;
  final Set<String> _reserved = {};
  final Map<String, String> _owners = {};
  final Map<String, int> _nextSuffix = {};
  final Map<String, Future<void>> _queues = {};
  final Map<String, _DirectoryPreparation> _directoryOperations = {};
  final Set<String> _directories = {};

  ReceivePathReservations({bool? caseInsensitive, Future<FileSystemEntityType> Function(String)? entryType})
    : caseInsensitive = caseInsensitive ?? (Platform.isWindows || Platform.isMacOS || Platform.isIOS),
      _entryType = entryType ?? ((path) => FileSystemEntity.type(path, followLinks: false));

  String _key(String path) {
    final normalized = p.normalize(p.absolute(path));
    return caseInsensitive ? normalized.toLowerCase() : normalized;
  }

  bool contains(String path) => _reserved.contains(_key(path));

  /// An in-flight directory occupies its name before asynchronous filesystem
  /// work starts. Sibling uploads share that work instead of rejecting each
  /// other or releasing the claim while another caller is still awaiting it.
  Future<void> prepareDirectory({
    required String path,
    required Future<void> Function(bool Function() hasActiveOwner) prepare,
    bool Function()? isActive,
  }) {
    ensureReceiveTargetActive(isActive);
    final key = _key(path);
    if (_reserved.contains(key)) {
      return Future.error(FileSystemException('Destination directory conflicts with a pending file', path));
    }
    final current = _directoryOperations[key];
    if (current != null) {
      current.owners.add(isActive);
      return current.completion.future;
    }
    final operation = _DirectoryPreparation()..owners.add(isActive);
    _directoryOperations[key] = operation;
    unawaited(() async {
      try {
        await prepare(() => operation.hasActiveOwner);
        // Keep the logical directory name for this receive session. A file
        // stat started before mkdir may return stale notFound after completion.
        // New directory callers still revalidate the real nofollow path type.
        _directories.add(key);
        operation.completion.complete();
      } catch (error, stack) {
        operation.completion.completeError(error, stack);
      } finally {
        if (identical(_directoryOperations[key], operation)) _directoryOperations.remove(key);
      }
    }());
    return operation.completion.future;
  }

  /// Claims only a candidate whose ownership was verified by the private core
  /// registry. This deliberately does not accept existing files by name alone.
  void reserveRecovery({required String path, required String owner, bool Function()? isActive}) {
    ensureReceiveTargetActive(isActive);
    final key = _key(path);
    if (_directories.contains(key) || _directoryOperations.containsKey(key) || (_reserved.contains(key) && _owners[key] != owner)) {
      throw FileSystemException('Recovery target is reserved by another receive file', path);
    }
    _reserved.add(key);
    _owners[key] = owner;
  }

  Future<String> allocate({required String directory, required String fileName, String? owner, bool Function()? isActive}) async {
    final base = _key(p.join(directory, fileName));
    final previous = _queues[base];
    final released = Completer<void>();
    _queues[base] = released.future;
    try {
      if (previous != null) await previous;
      var counter = _nextSuffix[base] ?? 1;
      while (true) {
        ensureReceiveTargetActive(isActive);
        final candidate = p.join(directory, counter == 1 ? fileName : fileName.withCount(counter));
        counter++;
        final key = _key(candidate);
        if (_reserved.contains(key) || _directories.contains(key) || _directoryOperations.containsKey(key)) continue;
        // File.exists misses directories and dangling links; all existing
        // entries occupy a name and must be preserved.
        final type = await _entryType(candidate);
        ensureReceiveTargetActive(isActive);
        if (type != FileSystemEntityType.notFound || _directories.contains(key) || _directoryOperations.containsKey(key)) continue;
        // Another base name may converge on this numbered name while awaiting IO.
        if (!_reserved.add(key)) continue;
        if (owner != null) _owners[key] = owner;
        _nextSuffix[base] = counter;
        return candidate;
      }
    } finally {
      released.complete();
      if (identical(_queues[base], released.future)) unawaited(_queues.remove(base));
    }
  }
}

/// Cancellation stops future target work; an OS operation already submitted may
/// still finish. Never delete an existing directory to simulate a rollback.
void ensureReceiveTargetActive(bool Function()? isActive) {
  if (isActive?.call() == false) throw StateError('Receive target is no longer active');
}

class _DirectoryPreparation {
  final completion = Completer<void>();
  final owners = <bool Function()?>[];
  bool get hasActiveOwner => owners.any((owner) => owner?.call() != false);
}
