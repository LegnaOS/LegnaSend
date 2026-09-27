import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:uuid/uuid.dart';

abstract interface class WorkspaceContentPersistence {
  Future<String?> read();
  Future<void> write(String value);
}

/// A durable observation counter, never an all-files digest or an If-Match value.
class WorkspaceContentState {
  final String sourceIdentity, contentEpoch;
  final String? verifiedIdentity;
  final int contentRevision;
  final bool dirty, observed;
  final int? lastObservedAt;
  const WorkspaceContentState({
    required this.sourceIdentity,
    required this.contentEpoch,
    this.verifiedIdentity,
    this.contentRevision = 0,
    this.dirty = true,
    this.observed = false,
    this.lastObservedAt,
  });

  WorkspaceContentState unknown() => WorkspaceContentState(
    sourceIdentity: sourceIdentity,
    contentEpoch: contentEpoch,
    verifiedIdentity: verifiedIdentity,
    contentRevision: contentRevision,
    lastObservedAt: lastObservedAt,
  );

  Map<String, Object?> toPublicJson() => {
    'contentEpoch': contentEpoch,
    'contentRevision': contentRevision,
    'contentKnowledge': observed ? 'observed' : 'unknown',
    'lastObservedAt': lastObservedAt,
    'dirty': dirty,
  };

  Map<String, Object?> _toJson() => {...toPublicJson(), 'sourceIdentity': sourceIdentity, 'verifiedIdentity': verifiedIdentity};

  @override
  String toString() => 'WorkspaceContentState(revision: $contentRevision, observed: $observed, dirty: $dirty)';
}

class _ContentBinding {
  final String owner, source;
  final int generation, listener, sequence;
  const _ContentBinding(this.owner, this.source, this.generation, this.listener, this.sequence);
}

/// Small serialized metadata writes only. No directory scan or file hashing.
/// The private source fingerprint is not exported to the browser or API.
class WorkspaceContentStore {
  static const _maxSafe = 9007199254740991;
  static final _canonicalUuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static bool _uuid(Object? value) => value is String && value.length == 36 && _canonicalUuid.stringMatch(value) == value;
  static bool _hash(Object? value) => value is String && value.length == 64 && _digest.stringMatch(value) == value;
  static bool _safeInt(Object? value, {int minimum = 0}) => value is int && value >= minimum && value <= _maxSafe;
  static bool _keys(Map value, Set<String> fields) => value.length == fields.length && fields.every(value.containsKey);
  final WorkspaceContentPersistence persistence;
  final void Function(Map<String, WorkspaceContentState> values, bool failed) onChanged;
  final AsyncSerialQueue _queue = AsyncSerialQueue();
  final Map<String, _ContentBinding> _bindings = {};
  Map<String, WorkspaceContentState> _values = {};
  bool _loaded = false, _disposed = false, _failed = false;
  int? _listener;

  WorkspaceContentStore({required this.persistence, required this.onChanged});

  static String sourceIdentity(DirectoryWorkspace entry) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'kind': entry.source.kind.name,
            'locator': entry.source.locator,
            'grantId': entry.source.grantId,
          }),
        ),
      )
      .toString();

  void dispose() {
    _disposed = true;
    _bindings.clear();
  }

  void _emit() {
    if (!_disposed) onChanged(Map.unmodifiable(_values), _failed);
  }

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final raw = await persistence.read();
      if (raw != null && utf8.encode(raw).length > 512 * 1024) throw const FormatException('Content state too large');
      final decoded = raw == null ? {'version': 1, 'entries': <String, dynamic>{}} : jsonDecode(raw);
      if (decoded is! Map ||
          !_keys(decoded, const {'version', 'entries'}) ||
          decoded['version'] is! int ||
          decoded['version'] != 1 ||
          decoded['entries'] is! Map ||
          (decoded['entries'] as Map).length > 512) {
        throw const FormatException('Invalid content state');
      }
      final next = <String, WorkspaceContentState>{};
      for (final entry in (decoded['entries'] as Map).entries) {
        final row = entry.value;
        if (!_uuid(entry.key) ||
            row is! Map ||
            !_keys(row, const {
              'sourceIdentity',
              'verifiedIdentity',
              'contentEpoch',
              'contentRevision',
              'contentKnowledge',
              'lastObservedAt',
              'dirty',
            }) ||
            !_hash(row['sourceIdentity']) ||
            (row['verifiedIdentity'] != null && !_hash(row['verifiedIdentity'])) ||
            !_uuid(row['contentEpoch']) ||
            !_safeInt(row['contentRevision']) ||
            (row['lastObservedAt'] != null && !_safeInt(row['lastObservedAt'])) ||
            !const ['observed', 'unknown'].contains(row['contentKnowledge']) ||
            row['dirty'] is! bool ||
            (row['dirty'] == true && row['contentKnowledge'] == 'observed')) {
          throw const FormatException('Invalid content record');
        }
        next[entry.key as String] = WorkspaceContentState(
          sourceIdentity: row['sourceIdentity'] as String,
          contentEpoch: row['contentEpoch'] as String,
          verifiedIdentity: row['verifiedIdentity'] as String?,
          contentRevision: row['contentRevision'] as int,
          lastObservedAt: row['lastObservedAt'] as int?,
        );
      }
      // Loading never restores "observed": offline changes may have happened.
      _values = next;
      _loaded = true;
      _failed = false;
      _emit();
    } catch (_) {
      _failed = true;
      _emit();
      throw StateError('Workspace content storage unavailable');
    }
  }

  Future<void> _save(Map<String, WorkspaceContentState> next, {bool Function()? isCurrent}) async {
    if (_disposed) throw StateError('Workspace content storage closed');
    try {
      if (next.length > 512) throw StateError('Workspace content storage full');
      final encoded = jsonEncode({
        'version': 1,
        'entries': {for (final e in next.entries) e.key: e.value._toJson()},
      });
      if (utf8.encode(encoded).length > 512 * 1024) throw StateError('Workspace content storage full');
      await persistence.write(encoded);
      if (_disposed) throw StateError('Workspace content storage closed');
      _values = isCurrent == null || isCurrent() ? next : {for (final e in next.entries) e.key: e.value.unknown()};
      _failed = false;
      _emit();
    } catch (_) {
      // Retain only committed counters. A failed write cannot become an acknowledgement.
      _values = {for (final e in _values.entries) e.key: e.value.unknown()};
      _failed = true;
      _emit();
      throw StateError('Workspace content storage unavailable');
    }
  }

  Future<void> synchronize(WorkspaceCatalogState Function() catalog, int? Function() listener) => _queue.run(() async {
    await _load();
    await _reconcile(catalog(), listener());
  });

  Future<void> _reconcile(WorkspaceCatalogState catalog, int? listener) async {
    if (_disposed) throw StateError('Workspace content storage closed');
    final listenerChanged = listener != _listener;
    _listener = listener;
    if (!catalog.initialized) {
      _bindings.clear();
      _values = {for (final e in _values.entries) e.key: e.value.unknown()};
      _emit();
      return;
    }
    final next = <String, WorkspaceContentState>{};
    var changed = listenerChanged || _failed || catalog.entries.length != _values.length;
    for (final entry in catalog.entries) {
      final identity = sourceIdentity(entry);
      final old = _values[entry.id];
      final binding = _bindings[entry.id];
      final locator = catalog.verifiedLocators[entry.id];
      final verifiedIdentity = locator == null ? null : sha256.convert(utf8.encode(locator)).toString();
      final sameSource = old?.sourceIdentity == identity && (verifiedIdentity == null || old?.verifiedIdentity == verifiedIdentity);
      var value = sameSource
          ? old!
          : WorkspaceContentState(sourceIdentity: identity, verifiedIdentity: verifiedIdentity, contentEpoch: const Uuid().v4());
      final eligible = catalog.matches(entry.id, entry.generation) && listener != null;
      if (listenerChanged || !eligible || (binding != null && (binding.generation != entry.generation || binding.source != identity))) {
        _bindings.remove(entry.id);
        if (value.observed || !value.dirty) changed = true;
        value = value.unknown();
      }
      if (!sameSource) {
        _bindings.remove(entry.id);
        changed = true;
      }
      next[entry.id] = value;
    }
    _bindings.removeWhere((id, _) => !next.containsKey(id));
    if (changed) await _save(next);
  }

  Future<String> handle({
    required String request,
    required WorkspaceCatalogState Function() catalog,
    required int? Function() listener,
    required int expectedListener,
  }) => _queue.run(() async {
    await _load();
    await _reconcile(catalog(), listener());
    if (_disposed || listener() != expectedListener || utf8.encode(request).length > 128 * 1024) throw StateError('Stale content observation');
    final value = jsonDecode(request);
    if (value is! Map<String, dynamic> ||
        !_keys(value, const {
          'version',
          'workspaceId',
          'generation',
          'owner',
          'sequence',
          'changed',
          'dirty',
          'scope',
          'observedAtUnixMs',
          'source',
          'kind',
        }) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        !_uuid(value['workspaceId']) ||
        !_safeInt(value['generation'], minimum: 1) ||
        !_uuid(value['owner']) ||
        !_safeInt(value['sequence']) ||
        value['changed'] is! bool ||
        value['dirty'] is! bool ||
        value['scope'] is! String ||
        utf8.encode(value['scope'] as String).length > 4096 ||
        !_safeInt(value['observedAtUnixMs']) ||
        value['source'] is! Map ||
        !const ['attach', 'observe', 'hint', 'published'].contains(value['kind'])) {
      throw const FormatException('Invalid content observation');
    }
    final id = value['workspaceId'] as String;
    final generation = value['generation'] as int;
    final current = catalog();
    final entries = current.publishable.where((e) => e.id == id && e.generation == generation);
    if (entries.length != 1) throw StateError('Stale content observation');
    final entry = entries.single;
    final source = value['source'] as Map;
    final locator = current.verifiedLocators[id];
    if (!_keys(source, const {'root', 'documentTree'}) ||
        source['root'] is! String ||
        (source['documentTree'] != null && source['documentTree'] is! String) ||
        source['root'] != (entry.source.kind == WorkspaceSourceKind.androidTree ? '' : locator) ||
        source['documentTree'] != (entry.source.kind == WorkspaceSourceKind.androidTree ? locator : null)) {
      throw StateError('Stale content source');
    }
    final identity = sourceIdentity(entry);
    final old = _values[id];
    if (old == null || old.sourceIdentity != identity) throw StateError('Content source unavailable');
    final owner = value['owner'] as String;
    final sequence = value['sequence'] as int;
    final kind = value['kind'];
    final binding = _bindings[id];
    if (binding != null &&
        binding.owner == owner &&
        binding.generation == generation &&
        binding.listener == expectedListener &&
        binding.source == identity &&
        binding.sequence == sequence) {
      return jsonEncode(old.toPublicJson());
    }
    if (kind == 'attach') {
      // An owner cannot displace another live owner for the same generation.
      if (sequence != 0 || binding != null) {
        throw StateError('Content owner changed');
      }
    } else if (binding == null ||
        binding.owner != owner ||
        binding.generation != generation ||
        binding.listener != expectedListener ||
        binding.source != identity ||
        sequence <= binding.sequence) {
      throw StateError('Stale content observation');
    }
    final known = (kind == 'observe' || kind == 'published') && value['dirty'] == false;
    final increment = kind == 'published' || (kind == 'observe' && value['changed'] == true);
    if (increment && old.contentRevision == _maxSafe) throw StateError('Content revision exhausted');
    final timestamp = value['observedAtUnixMs'] as int;
    final next = WorkspaceContentState(
      sourceIdentity: identity,
      contentEpoch: old.contentEpoch,
      verifiedIdentity: old.verifiedIdentity,
      contentRevision: old.contentRevision + (increment ? 1 : 0),
      observed: known,
      dirty: !known,
      lastObservedAt: (kind == 'observe' || kind == 'published') && (old.lastObservedAt == null || timestamp > old.lastObservedAt!)
          ? timestamp
          : old.lastObservedAt,
    );
    bool stillCurrent() =>
        listener() == expectedListener &&
        catalog().matches(id, generation) &&
        catalog().verifiedLocators[id] == locator &&
        catalog().entries.any((e) => e.id == id && sourceIdentity(e) == identity);
    await _save({..._values, id: next}, isCurrent: stillCurrent);
    // A catalogue mutation or listener restart during the write does not receive
    // an authoritative reply. Reconciliation invalidates the persisted baseline.
    if (!stillCurrent()) {
      await _reconcile(catalog(), listener());
      throw StateError('Stale content observation');
    }
    _bindings[id] = _ContentBinding(owner, identity, generation, expectedListener, sequence);
    return jsonEncode(next.toPublicJson());
  });
}
