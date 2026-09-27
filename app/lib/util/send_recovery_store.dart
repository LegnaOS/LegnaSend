import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class SendRecoveryException implements Exception {
  final String code;
  const SendRecoveryException(this.code);
  @override
  String toString() => 'SendRecoveryException($code)';
}

/// File-level recovery only: never persists peer sessions, tokens or PINs.
/// Progress is independent of the immutable manifest and copied memory sources.
class SendRecoveryStore {
  final Directory root;
  final List<String> issues = [];
  static const _maxFiles = 100000;
  static const _maxJsonBytes = 32 * 1024 * 1024;
  static const _maxSize = 1 << 50;
  static final Map<String, Future<void>> _writers = {};
  static int _nonce = 0;
  static const _lockName = '.send-recovery.lock';
  static const _sessionLockName = '.send-recovery.session.lock';
  static final Set<String> _claimedRoots = {};
  RandomAccessFile? _sessionLock;
  String? _claimedRoot;
  Future<void>? _claiming;

  SendRecoveryStore(this.root);

  Future<T> _serial<T>(Future<T> Function() action) async {
    final base = await _root();
    final key = base.path;
    final previous = _writers[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _writers[key] = gate.future;
    await previous;
    RandomAccessFile? lock;
    try {
      final file = File(p.join(base.path, _lockName));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
        throw const SendRecoveryException('unsafePath');
      }
      // Cooperative cross-process serialization. Keep the inode for the life
      // of the journal: unlinking a held lock would allow a second independent
      // lock to be created. Dart has no open-no-follow primitive; these checks
      // do not claim protection against a hostile same-user replacement race.
      lock = await file.open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        throw const SendRecoveryException('unsafePath');
      }
      return await action();
    } finally {
      try {
        await lock?.close(); // Closing also releases the OS lock after failures.
      } finally {
        gate.complete();
        if (identical(_writers[key], gate.future)) unawaited(_writers.remove(key));
      }
    }
  }

  /// A single app session owns restoration/checkpoints. Transaction locking
  /// alone cannot distinguish another live app's sending jobs from a crash.
  Future<void> claimSession() {
    if (_sessionLock != null) return Future<void>.value();
    return _claiming ??= _claimSession().whenComplete(() => _claiming = null);
  }

  Future<void> _claimSession() async {
    final base = await _root();
    final key = base.path;
    if (!_claimedRoots.add(key)) throw const SendRecoveryException('busy');
    RandomAccessFile? lock;
    try {
      final file = File(p.join(base.path, _sessionLockName));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
        throw const SendRecoveryException('unsafePath');
      }
      lock = await file.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive); // Non-blocking: another app stays usable.
      } on FileSystemException catch (error) {
        if ([11, 13, 32, 33, 35].contains(error.osError?.errorCode)) throw const SendRecoveryException('busy');
        rethrow;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
        throw const SendRecoveryException('unsafePath');
      }
      _sessionLock = lock;
      _claimedRoot = key;
    } catch (_) {
      try {
        await lock?.close();
      } finally {
        _claimedRoots.remove(key);
      }
      rethrow;
    }
  }

  Future<void> releaseSession() async {
    final pending = _claiming;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        return; // A failed claim owns neither the root nor its OS lock.
      }
    }
    final lock = _sessionLock;
    final key = _claimedRoot;
    _sessionLock = null;
    _claimedRoot = null;
    try {
      await lock?.close();
    } finally {
      if (key != null) _claimedRoots.remove(key);
    }
  }

  String _key(String id) => sha256.convert(utf8.encode(_string(id))).toString();

  Future<Directory> _root() async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const SendRecoveryException('unsafePath');
    }
    // Canonicalize platform aliases (for example macOS /var) once, then keep all
    // owned objects directly inside this directory without following links.
    return Directory(await root.resolveSymbolicLinks());
  }

  Future<Directory> _directory(String id) async {
    final base = await _root();
    final directory = Directory(p.join(base.path, _key(id)));
    if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const SendRecoveryException('unsafePath');
    }
    return directory;
  }

  Future<Map<String, dynamic>> _read(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
      throw const SendRecoveryException('unsafePath');
    }
    final length = await file.length();
    if (length <= 0 || length > _maxJsonBytes) throw const SendRecoveryException('invalidRecord');
    return _map(jsonDecode(await file.readAsString()));
  }

  Future<void> _atomic(File destination, Map<String, dynamic> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > _maxJsonBytes) throw const SendRecoveryException('invalidRecord');
    final type = await FileSystemEntity.type(destination.path, followLinks: false);
    if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) throw const SendRecoveryException('unsafePath');
    final temp = File('${destination.path}.writing-$pid-${_nonce++}');
    try {
      await temp.create(exclusive: true);
      await temp.writeAsBytes(bytes, flush: true);
      // Do not delete the previous version first: a failed replacement must
      // leave it readable, including on platforms that reject a rename.
      await temp.rename(destination.path);
    } finally {
      if (await FileSystemEntity.type(temp.path, followLinks: false) == FileSystemEntityType.file) await temp.delete();
    }
  }

  Future<Map<String, dynamic>> _owner(Directory directory, String id) async {
    final owner = await _read(File(p.join(directory.path, 'owner.json')));
    if (owner['version'] is! int || owner['version'] != 1 || owner['id'] != id || p.basename(directory.path) != _key(id)) {
      throw const SendRecoveryException('invalidRecord');
    }
    _integer(owner['count'], min: 1, max: _maxFiles);
    return owner;
  }

  Future<SendJob> saveManifest(SendJob job, {bool copyLocalSources = false}) => _serial(() async {
    if (job.files.isEmpty || job.files.length > _maxFiles) throw const SendRecoveryException('invalidRecord');
    if (job.resumeKeys.isNotEmpty &&
        (job.resumeKeys.length != job.files.length ||
            job.resumeKeys.toSet().length != job.resumeKeys.length ||
            job.resumeKeys.any((key) => !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(key)))) {
      throw const SendRecoveryException('invalidRecord');
    }
    final channel = job.selectedChannel;
    final localRoute = _localRoute(job.localRoute?.toJson());
    if (channel != null) _channel(channel.toJson());
    _device(job.target.toJson());
    var total = 0;
    for (final file in job.files) {
      total += _integer(file.size, max: _maxSize);
      if (total > _maxSize) throw const SendRecoveryException('invalidRecord');
      _string(file.name);
      if (file.lastModified != null) _string(file.lastModified);
      if (file.lastAccessed != null) _string(file.lastAccessed);
    }
    final base = await _root();
    final directory = Directory(p.join(base.path, _key(job.id)));
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      await _owner(await _directory(job.id), job.id);
      // Never silently replace a manifest belonging to another source snapshot.
      final existing = await _manifest(directory, job.id);
      if (_localRoute(existing['localRoute']) != localRoute) throw const SendRecoveryException('invalidRecord');
      if (existing['files'] is List && (existing['files'] as List).length == job.files.length) return _snapshot(job, directory, existing);
      throw const SendRecoveryException('invalidRecord');
    }
    await directory.create();
    await _atomic(File(p.join(directory.path, 'owner.json')), {'version': 1, 'id': job.id, 'count': job.files.length});
    final files = <Map<String, dynamic>>[];
    for (var i = 0; i < job.files.length; i++) {
      final file = job.files[i];
      _integer(file.size, max: _maxSize);
      final record = <String, dynamic>{
        'resumeKey': job.resumeKeys.length == job.files.length ? job.resumeKeys[i] : const Uuid().v4(),
        'name': _string(file.name),
        'type': file.fileType.name,
        'size': file.size,
        'lastModified': file.lastModified,
        'lastAccessed': file.lastAccessed,
      };
      if (file.bytes != null) {
        if (file.bytes!.length != file.size) throw const SendRecoveryException('sourceChanged');
        final source = File(p.join(directory.path, 'source-$i'));
        await source.create(exclusive: true);
        final handle = await source.open(mode: FileMode.writeOnly);
        try {
          for (var offset = 0; offset < file.bytes!.length; offset += 256 * 1024) {
            final end = (offset + 256 * 1024).clamp(0, file.bytes!.length);
            await handle.writeFrom(file.bytes!, offset, end);
          }
          await handle.flush();
        } finally {
          await handle.close();
        }
        record.addAll({'kind': 'owned', 'path': 'source-$i', 'modified': (await source.stat()).modified.microsecondsSinceEpoch});
      } else if (file.path != null && file.path!.startsWith('content://')) {
        record.addAll({'kind': 'permission', 'path': _string(file.path), 'modified': 0});
      } else if (file.path != null && p.isAbsolute(file.path!)) {
        final stat = await _sourceStat(file.path!);
        if (stat.size != file.size) throw const SendRecoveryException('sourceChanged');
        if (copyLocalSources || p.isWithin(base.path, p.normalize(file.path!))) {
          // A retry owns its sources before the previous history is removed.
          if (p.isWithin(base.path, p.normalize(file.path!))) {
            final oldDirectory = Directory(p.dirname(file.path!));
            final oldOwner = await _read(File(p.join(oldDirectory.path, 'owner.json')));
            final oldId = _string(oldOwner['id']);
            final oldManifest = await _manifest(await _directory(oldId), oldId);
            final sourceName = p.basename(file.path!);
            if (!(oldManifest['files'] as List).any((item) => item['kind'] == 'owned' && item['path'] == sourceName)) {
              throw const SendRecoveryException('unsafePath');
            }
          }
          final source = File(p.join(directory.path, 'source-$i'));
          await source.create(exclusive: true);
          final sink = source.openWrite();
          try {
            await sink.addStream(File(file.path!).openRead());
            await sink.flush();
          } finally {
            await sink.close();
          }
          final copied = await source.stat();
          final after = await _sourceStat(file.path!);
          if (copied.size != file.size || after.size != stat.size || after.modified != stat.modified) {
            throw const SendRecoveryException('sourceChanged');
          }
          record.addAll({'kind': 'owned', 'path': 'source-$i', 'modified': copied.modified.microsecondsSinceEpoch});
        } else {
          record.addAll({'kind': 'local', 'path': _string(file.path), 'modified': stat.modified.microsecondsSinceEpoch});
        }
      } else {
        throw const SendRecoveryException('unsupported');
      }
      files.add(record);
    }
    final manifest = <String, dynamic>{
      'version': 1,
      'id': job.id,
      'target': job.target.toJson(),
      'channel': channel?.toJson(),
      'localRoute': localRoute?.toJson(),
      'files': files,
    };
    _device(manifest['target']);
    await _atomic(File(p.join(directory.path, 'manifest.json')), manifest);
    return _snapshot(job, directory, manifest, preserveRuntime: true);
  });

  Future<Map<String, dynamic>> _manifest(Directory directory, String id) async {
    final owner = await _owner(directory, id);
    final manifest = await _read(File(p.join(directory.path, 'manifest.json')));
    if (manifest['version'] is! int || manifest['version'] != 1 || manifest['id'] != id) throw const SendRecoveryException('invalidRecord');
    final files = manifest['files'];
    if (files is! List || files.length != owner['count']) throw const SendRecoveryException('invalidRecord');
    _device(manifest['target']);
    if (!manifest.containsKey('channel')) throw const SendRecoveryException('invalidRecord');
    if (manifest['channel'] != null) _channel(manifest['channel']);
    _localRoute(manifest['localRoute']);
    var total = 0;
    for (var i = 0; i < files.length; i++) {
      final record = _map(files[i]);
      _string(record['name']);
      if (!FileType.values.any((type) => type.name == record['type'])) throw const SendRecoveryException('invalidRecord');
      total += _integer(record['size'], max: _maxSize);
      if (total > _maxSize) throw const SendRecoveryException('invalidRecord');
      _integer(record['modified'], min: -8640000000000000000, max: 8640000000000000000);
      for (final name in ['lastModified', 'lastAccessed']) {
        if (record[name] != null) _string(record[name]);
      }
      final path = _string(record['path']);
      switch (record['kind']) {
        case 'owned':
          if (path != 'source-$i') throw const SendRecoveryException('unsafePath');
        case 'local':
          if (!p.isAbsolute(path) || path.startsWith('content://')) throw const SendRecoveryException('unsafePath');
        case 'permission':
          if (!path.startsWith('content://')) throw const SendRecoveryException('invalidRecord');
        default:
          throw const SendRecoveryException('invalidRecord');
      }
    }
    final keys = <String>{};
    var migrated = false;
    for (final item in files) {
      final record = item as Map<String, dynamic>;
      if (!record.containsKey('resumeKey')) {
        record['resumeKey'] = const Uuid().v4();
        migrated = true;
      }
      final key = record['resumeKey'];
      if (key is! String || !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(key) || !keys.add(key)) {
        throw const SendRecoveryException('invalidRecord');
      }
    }
    // Do not expose newly generated identities unless the atomic write succeeds.
    if (migrated) await _atomic(File(p.join(directory.path, 'manifest.json')), manifest);
    return manifest;
  }

  Future<void> saveProgress(String jobId, {required Set<int> completed, required Set<int> skipped}) {
    // Snapshot before the first await. Neither caller mutation nor reordered
    // root-resolution I/O may change what this checkpoint acknowledges.
    final incomingCompleted = Set<int>.of(completed);
    final incomingSkipped = Set<int>.of(skipped);
    return _serial(() async {
      final directory = await _directory(jobId);
      final owner = await _owner(directory, jobId);
      final count = owner['count'] as int;
      _indices(incomingCompleted.toList(), count);
      _indices(incomingSkipped.toList(), count);
      if (incomingCompleted.intersection(incomingSkipped).isNotEmpty) throw const SendRecoveryException('invalidRecord');
      final progressFile = File(p.join(directory.path, 'progress.json'));
      final confirmed = <int>{...incomingCompleted};
      final omitted = <int>{...incomingSkipped};
      if (await FileSystemEntity.type(progressFile.path, followLinks: false) != FileSystemEntityType.notFound) {
        final existing = await _read(progressFile);
        if (existing['version'] is! int || existing['version'] != 1 || existing['id'] != jobId) {
          throw const SendRecoveryException('invalidRecord');
        }
        confirmed.addAll(_indices(existing['completed'], count));
        omitted.addAll(_indices(existing['skipped'], count));
      }
      // Outcomes for an immutable manifest are append-only. An older or
      // partial checkpoint must never remove acknowledgements already on disk.
      // Conflicting success/skip classifications are not resolved by arrival
      // order: retain the existing record and require explicit investigation.
      if (confirmed.intersection(omitted).isNotEmpty) throw const SendRecoveryException('invalidRecord');
      await _atomic(progressFile, {
        'version': 1,
        'id': jobId,
        'completed': confirmed.toList()..sort(),
        'skipped': omitted.toList()..sort(),
      });
    });
  }

  Future<List<SendJob>> load() => _serial(() async {
    issues.clear();
    final base = await _root();
    final result = <SendJob>[];
    await for (final entity in base.list(followLinks: false)) {
      final key = p.basename(entity.path);
      if ((key == _lockName || key == _sessionLockName) && entity is File) continue;
      try {
        if (entity is! Directory || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) throw const SendRecoveryException('unsafePath');
        final owner = await _read(File(p.join(entity.path, 'owner.json')));
        final id = _string(owner['id']);
        final manifest = await _manifest(entity, id);
        final records = manifest['files'] as List;
        var completed = <int>{};
        var skipped = <int>{};
        final progressFile = File(p.join(entity.path, 'progress.json'));
        if (await FileSystemEntity.type(progressFile.path, followLinks: false) != FileSystemEntityType.notFound) {
          final progress = await _read(progressFile);
          if (progress['version'] is! int || progress['version'] != 1 || progress['id'] != id) throw const SendRecoveryException('invalidRecord');
          completed = _indices(progress['completed'], records.length);
          skipped = _indices(progress['skipped'], records.length);
          if (completed.intersection(skipped).isNotEmpty) throw const SendRecoveryException('invalidRecord');
        }
        final files = <CrossFile>[];
        for (final item in records) {
          final record = _map(item);
          files.add(
            CrossFile(
              name: record['name'] as String,
              fileType: FileType.values.byName(record['type'] as String),
              size: record['size'] as int,
              path: record['kind'] == 'owned' ? p.join(entity.path, record['path'] as String) : record['path'] as String,
              lastModified: record['lastModified'] as String?,
              lastAccessed: record['lastAccessed'] as String?,
              bytes: null,
              asset: null,
              thumbnail: null,
            ),
          );
        }
        // Startup reads only private metadata, never external or network disks.
        final pendingPermission = records.asMap().entries.any(
          (entry) => !completed.contains(entry.key) && !skipped.contains(entry.key) && entry.value['kind'] == 'permission',
        );
        final issue = pendingPermission ? 'sourcePermission' : null;
        result.add(
          SendJob(
            id: id,
            target: _device(manifest['target']),
            selectedChannel: manifest['channel'] == null ? null : _channel(manifest['channel']),
            localRoute: _localRoute(manifest['localRoute']),
            files: files,
            resumeKeys: List.unmodifiable([for (final record in records) record['resumeKey'] as String]),
            resumeKeysPersisted: true,
            status: completed.length + skipped.length == files.length ? SendJobStatus.succeeded : SendJobStatus.failed,
            restored: true,
            completedIndices: completed,
            skippedIndices: skipped,
            recoveryIssue: issue,
          ),
        );
      } catch (e) {
        issues.add('$key:${e is SendRecoveryException ? e.code : 'invalidRecord'}');
      }
    }
    return result;
  });

  SendJob _snapshot(SendJob job, Directory directory, Map<String, dynamic> manifest, {bool preserveRuntime = false}) {
    final files = (manifest['files'] as List).asMap().entries.map((entry) {
      final record = _map(entry.value);
      final original = preserveRuntime ? job.files[entry.key] : null;
      return CrossFile(
        name: record['name'] as String,
        fileType: FileType.values.byName(record['type'] as String),
        size: record['size'] as int,
        path: record['kind'] == 'owned' ? p.join(directory.path, record['path'] as String) : record['path'] as String,
        lastModified: record['lastModified'] as String?,
        lastAccessed: record['lastAccessed'] as String?,
        bytes: original?.bytes,
        asset: original?.asset,
        thumbnail: original?.thumbnail,
      );
    }).toList();
    return SendJob(
      id: job.id,
      attemptRevision: job.attemptRevision,
      attemptIndices: job.attemptIndices,
      target: _device(manifest['target']),
      selectedChannel: manifest['channel'] == null ? null : _channel(manifest['channel']),
      localRoute: _localRoute(manifest['localRoute']),
      files: files,
      resumeKeys: List.unmodifiable([for (final record in manifest['files'] as List) record['resumeKey'] as String]),
      resumeKeysPersisted: true,
      status: job.status,
      result: job.result,
      error: job.error,
      restored: job.restored,
      completedIndices: job.completedIndices,
      skippedIndices: job.skippedIndices,
      recoveryIssue: job.recoveryIssue,
      recoveryChecking: job.recoveryChecking,
    );
  }

  Future<void> validateRemaining(SendJob job) => _serial(() async {
    final directory = await _directory(job.id);
    final manifest = await _manifest(directory, job.id);
    if (_localRoute(manifest['localRoute']) != job.localRoute) throw const SendRecoveryException('invalidRecord');
    final records = manifest['files'] as List;
    _indices(job.completedIndices.toList(), records.length);
    _indices(job.skippedIndices.toList(), records.length);
    await _validate(directory, records, job.completedIndices.union(job.skippedIndices));
  });

  Future<void> _validate(Directory directory, List<dynamic> records, Set<int> finished) async {
    for (var i = 0; i < records.length; i++) {
      if (finished.contains(i)) continue;
      final record = _map(records[i]);
      if (record['kind'] == 'permission') throw const SendRecoveryException('sourcePermission');
      final path = record['kind'] == 'owned' ? p.join(directory.path, record['path'] as String) : record['path'] as String;
      final stat = await _sourceStat(path);
      if (stat.size != record['size'] || stat.modified.microsecondsSinceEpoch != record['modified']) {
        throw const SendRecoveryException('sourceChanged');
      }
    }
  }

  // Size and mtime do not detect equal-size/equal-mtime replacement.
  Future<FileStat> _sourceStat(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw const SendRecoveryException('sourceMissing');
    if (type != FileSystemEntityType.file) throw const SendRecoveryException('unsafePath');
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) throw const SendRecoveryException('sourceMissing');
      if (stat.type != FileSystemEntityType.file) throw const SendRecoveryException('unsafePath');
      return stat;
    } on FileSystemException {
      throw const SendRecoveryException('sourcePermission');
    }
  }

  Future<void> remove(String jobId) => _serial(() async {
    final base = await _root();
    final path = p.join(base.path, _key(jobId));
    if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.notFound) return;
    final directory = await _directory(jobId);
    final owner = await _owner(directory, jobId);
    final allowed = {'manifest.json', 'progress.json', for (var i = 0; i < owner['count']; i++) 'source-$i'};
    final entries = await directory.list(followLinks: false).toList();
    if (entries.any((entity) => entity is! File || (!allowed.contains(p.basename(entity.path)) && p.basename(entity.path) != 'owner.json'))) {
      throw const SendRecoveryException('unsafePath');
    }
    // Never recurse and never delete paths from source metadata.
    for (final entity in entries) {
      if (p.basename(entity.path) != 'owner.json') await entity.delete();
    }
    await File(p.join(directory.path, 'owner.json')).delete();
    await directory.delete();
  });

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map<String, dynamic>) throw const SendRecoveryException('invalidRecord');
    return value;
  }

  static String _string(Object? value) {
    if (value is! String || value.isEmpty || value.length > 32768 || value.contains('\u0000')) throw const SendRecoveryException('invalidRecord');
    return value;
  }

  static int _integer(Object? value, {int min = 0, int max = _maxSize}) {
    if (value is! int || value < min || value > max) throw const SendRecoveryException('invalidRecord');
    return value;
  }

  static Set<int> _indices(Object? value, int count) {
    if (value is! List || value.length > count) throw const SendRecoveryException('invalidRecord');
    final result = value.map((index) => _integer(index, max: count - 1)).toSet();
    if (result.length != value.length) throw const SendRecoveryException('invalidRecord');
    return result;
  }

  static LocalSendRoute? _localRoute(Object? value) {
    if (value == null) return null; // Legacy manifests use automatic OS routing.
    final map = _map(value);
    if (!map.containsKey('interfaceName') ||
        !map.containsKey('localAddress') ||
        map.keys.any((key) => !['interfaceName', 'localAddress', 'androidNetworkHandle', 'androidNetworkEpoch'].contains(key))) {
      throw const SendRecoveryException('invalidRecord');
    }
    final name = _string(map['interfaceName']);
    final address = _string(map['localAddress']);
    final ip = InternetAddress.tryParse(address);
    if (name.length > 255 || address.length > 128 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) || address.contains('%') || ip == null) {
      throw const SendRecoveryException('invalidRecord');
    }
    final handle = map['androidNetworkHandle'];
    final epoch = map['androidNetworkEpoch'];
    if ((handle == null) != (epoch == null) ||
        handle != null &&
            (handle is! String ||
                !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(handle) ||
                BigInt.parse(handle) > ((BigInt.one << 64) - BigInt.one) ||
                epoch is! String ||
                !RegExp(r'^[a-f0-9-]{36}:[a-f0-9-]{36}$').hasMatch(epoch))) {
      throw const SendRecoveryException('invalidRecord');
    }
    return LocalSendRoute(interfaceName: name, localAddress: address, androidNetworkHandle: handle as String?, androidNetworkEpoch: epoch as String?);
  }

  static HttpChannel _channel(Object? value) {
    final map = _map(value);
    final host = _string(map['host']);
    final port = _integer(map['port'], min: 1, max: 65535);
    if (map['https'] is! bool) throw const SendRecoveryException('invalidRecord');
    return HttpChannel(host: host, port: port, https: map['https'] as bool);
  }

  static Device _device(Object? value) {
    final map = _map(value);
    _string(map['alias']);
    _string(map['version']);
    if (map['fingerprint'] is! String || (map['fingerprint'] as String).length > 4096 || map['https'] is! bool || map['download'] is! bool) {
      throw const SendRecoveryException('invalidRecord');
    }
    _integer(map['port'], min: 1, max: 65535);
    if (!DeviceType.values.any((type) => type.name == map['deviceType'])) throw const SendRecoveryException('invalidRecord');
    final channels = map['channels'];
    if (channels is! List || channels.length > 128) throw const SendRecoveryException('invalidRecord');
    for (final channel in channels) {
      final entry = _map(channel);
      if (entry['host'] != null) {
        _channel(entry);
      } else {
        _string(entry['signalingServer']);
      }
    }
    for (final key in ['ip', 'deviceModel', 'signalingId']) {
      if (map[key] != null) _string(map[key]);
    }
    return DeviceMapper.fromJson(map);
  }
}
