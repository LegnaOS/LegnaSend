import 'dart:async';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_app/util/workspace/approved_workspace_source.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';
import 'package:uuid/uuid.dart';

abstract interface class WorkspaceCatalogStore {
  Future<String?> read();
  Future<void> write(String value);
}

enum WorkspaceCatalogFailure { read, malformed, write }

class WorkspaceCatalogException implements Exception {
  final WorkspaceCatalogFailure failure;

  const WorkspaceCatalogException(this.failure);

  @override
  String toString() => 'WorkspaceCatalogException(${failure.name})';
}

enum WorkspaceManagementAction { update, enable, disable, validate, destroy, configure, password }

enum WorkspaceManagementFailure { notFound, staleGeneration, claimRejected, sourceNotApproved, mustBeClosed }

class WorkspaceManagementException implements Exception {
  final WorkspaceManagementFailure failure;
  const WorkspaceManagementException(this.failure);
}

enum WorkspaceBatchOutcome { applied, invalid, changed, failed }

class WorkspaceBatchResult {
  final String id;
  final String name;
  final WorkspaceBatchOutcome outcome;
  const WorkspaceBatchResult(this.id, this.name, this.outcome);
}

class WorkspaceCatalogState {
  final List<DirectoryWorkspace> entries;
  final List<ApprovedWorkspaceSource> approvedSources;

  /// Validated locators are runtime-only. Their source kind decides whether they
  /// are real filesystem paths or opaque document-tree URIs; never interchange them.
  final Map<String, String> verifiedLocators;
  final bool initialized;
  final bool checking;
  final WorkspaceCatalogFailure? failure;

  const WorkspaceCatalogState({
    this.entries = const [],
    this.approvedSources = const [],
    this.verifiedLocators = const {},
    this.initialized = false,
    this.checking = false,
    this.failure,
  });

  /// Candidates for a future route publisher, NOT currently served workspaces.
  Iterable<DirectoryWorkspace> get publishable => entries.where((entry) => initialized && entry.enabled && verifiedLocators.containsKey(entry.id));

  bool matches(String id, int generation) => publishable.any((entry) => entry.id == id && entry.generation == generation);
}

/// Owns durable configuration, not sockets, sessions, filesystem content or UI.
/// All mutations (including validation) are serialized, so a late directory
/// result cannot resurrect a workspace after a queued close/destroy.
class WorkspaceCatalog {
  final WorkspaceCatalogStore store;
  final WorkspaceDirectoryProbe probe;
  final WorkspaceWriteProbe writeProbe;
  final Duration probeTimeout;
  final void Function(WorkspaceCatalogState)? onChanged;
  final String Function() _newId;
  final _queue = AsyncSerialQueue();
  Future<void>? _initialization;
  bool _disposed = false;
  WorkspaceCatalogState _state = const WorkspaceCatalogState();

  WorkspaceCatalog({
    required this.store,
    this.probe = probeWorkspaceDirectory,
    this.writeProbe = probeWorkspaceWriteAccess,
    this.probeTimeout = const Duration(seconds: 3),
    this.onChanged,
    String Function()? newId,
  }) : _newId = newId ?? const Uuid().v4;

  WorkspaceCatalogState get state => _state;

  Future<void> initialize() => _initialization ??= _queue.run(_load);

  /// Explicit retry after a storage/configuration repair. Failed loads are never
  /// silently replaced by an empty catalog, and writes stay blocked until valid.
  Future<void> reload() => _initialization = _queue.run(_load);

  void dispose() => _disposed = true;

  void _checkAlive() {
    if (_disposed) throw StateError('Workspace catalog is disposed');
  }

  void _emit(WorkspaceCatalogState value) {
    _checkAlive();
    _state = value;
    onChanged?.call(value);
  }

  Future<void> _load() async {
    _checkAlive();
    // No old root is eligible while the persisted catalog is being rechecked.
    _emit(WorkspaceCatalogState(entries: _state.entries, checking: true));
    final String? raw;
    try {
      raw = await store.read();
    } catch (_) {
      _emit(const WorkspaceCatalogState(failure: WorkspaceCatalogFailure.read));
      throw const WorkspaceCatalogException(WorkspaceCatalogFailure.read);
    }
    final List<DirectoryWorkspace> entries;
    final List<ApprovedWorkspaceSource> approvedSources;
    try {
      entries = WorkspaceCatalogCodec.decode(raw);
      approvedSources = WorkspaceCatalogCodec.decodeApprovals(raw);
    } catch (_) {
      _emit(const WorkspaceCatalogState(failure: WorkspaceCatalogFailure.malformed));
      throw const WorkspaceCatalogException(WorkspaceCatalogFailure.malformed);
    }
    final next = entries.toList();
    final roots = <String, String>{};
    final enabled = [
      for (var i = 0; i < entries.length; i++)
        if (entries[i].enabled) i,
    ];
    // Bound concurrent probes; never recursively enumerate a shared directory.
    for (var offset = 0; offset < enabled.length; offset += 4) {
      _checkAlive();
      final batch = enabled.skip(offset).take(4);
      await Future.wait(
        batch.map((index) async {
          final entry = entries[index];
          final result = await _probe(entry);
          next[index] = entry.copyWith(enabled: result.isValid, generation: entry.generation + 1, invalidReason: result.invalidReason);
          if (result.isValid) roots[entry.id] = result.verifiedLocator!;
        }),
      );
    }
    // Persist automatic disable and new generations before publishing candidates.
    if (enabled.isNotEmpty) {
      try {
        await _persist(next, approvedSources: approvedSources);
      } catch (_) {
        _emit(WorkspaceCatalogState(entries: entries, failure: WorkspaceCatalogFailure.write));
        rethrow;
      }
    }
    _emit(
      WorkspaceCatalogState(
        entries: List.unmodifiable(next),
        approvedSources: approvedSources,
        verifiedLocators: Map.unmodifiable(roots),
        initialized: true,
      ),
    );
  }

  Future<WorkspaceProbeResult> _probe(DirectoryWorkspace entry) async {
    final result = await _probeRequirements(entry);
    if (!result.isValid && _state.initialized && _state.verifiedLocators.containsKey(entry.id)) {
      // Known-invalid runtime authority must not survive a subsequent failed
      // persistence write and poison the next atomic server configuration.
      _emit(
        WorkspaceCatalogState(
          entries: _state.entries,
          approvedSources: _state.approvedSources,
          verifiedLocators: Map.unmodifiable({..._state.verifiedLocators}..remove(entry.id)),
          initialized: true,
          failure: _state.failure,
        ),
      );
    }
    return result;
  }

  Future<WorkspaceProbeResult> _probeRequirements(DirectoryWorkspace entry) async {
    final source = entry.source;
    try {
      final result = await probeWorkspaceEntry(entry, readProbe: probe, writeProbe: writeProbe).timeout(probeTimeout);
      if (result.isValid && (result.verifiedLocator == null || result.verifiedLocator!.isEmpty)) {
        return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.ioError);
      }
      if (result.isValid && ((source.kind == WorkspaceSourceKind.androidTree) != (result.documentTree != null))) {
        return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.ioError);
      }
      if (result.documentTree != null && result.documentTree != source.locator) {
        return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.grantUnavailable);
      }
      return result;
    } on TimeoutException {
      return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.timeout);
    } catch (_) {
      return const WorkspaceProbeResult.invalid(WorkspaceInvalidReason.ioError);
    }
  }

  Future<void> _persist(List<DirectoryWorkspace> entries, {List<ApprovedWorkspaceSource>? approvedSources}) async {
    _checkAlive();
    final encoded = WorkspaceCatalogCodec.encode(entries, approvedSources: approvedSources ?? _state.approvedSources);
    try {
      await store.write(encoded);
    } catch (_) {
      throw const WorkspaceCatalogException(WorkspaceCatalogFailure.write);
    }
  }

  Future<T> _mutate<T>(Future<T> Function() operation) async {
    await initialize();
    return _queue.run(() async {
      _checkAlive();
      if (!_state.initialized) throw StateError('Workspace catalog requires recovery');
      return operation();
    });
  }

  DirectoryWorkspace _entry(String id) => _state.entries.firstWhere((entry) => entry.id == id, orElse: () => throw StateError('Unknown workspace'));

  Future<void> _commit(List<DirectoryWorkspace> entries, Map<String, String> roots, {List<ApprovedWorkspaceSource>? approvedSources}) async {
    final approvals = List<ApprovedWorkspaceSource>.unmodifiable(approvedSources ?? _state.approvedSources);
    await _persist(entries, approvedSources: approvals);
    _emit(
      WorkspaceCatalogState(
        entries: List.unmodifiable(entries),
        approvedSources: approvals,
        verifiedLocators: Map.unmodifiable(roots),
        initialized: true,
      ),
    );
  }

  Future<DirectoryWorkspace> _replace(DirectoryWorkspace entry, {String? root}) async {
    final next = [
      for (final previous in _state.entries)
        if (previous.id == entry.id) entry else previous,
    ];
    final roots = {..._state.verifiedLocators}..remove(entry.id);
    if (entry.enabled && root != null) roots[entry.id] = root;
    await _commit(next, roots);
    return entry;
  }

  /// Creation is closed by default. Explicit enable performs a real probe.
  Future<DirectoryWorkspace> create({required String name, required String slug, required WorkspaceSource source, bool visible = true}) =>
      _mutate(() async {
        final entry = DirectoryWorkspace(
          id: _newId(),
          name: name.trim(),
          slug: WorkspaceCatalogCodec.normalizeSlug(slug),
          source: source,
          enabled: false,
          visible: visible,
          generation: 1,
        );
        await _commit([..._state.entries, entry], _state.verifiedLocators);
        return entry;
      });

  Future<DirectoryWorkspace> update(String id, {String? name, String? slug, WorkspaceSource? source, bool? visible}) => _mutate(() async {
    final old = _entry(id);
    final nextSlug = slug == null ? old.slug : WorkspaceCatalogCodec.normalizeSlug(slug);
    final nextSource = source ?? old.source;
    // A root/route replacement must be preceded by explicit shutdown, so an
    // old URL/session can never accidentally identify a new shared directory.
    if (old.enabled && (nextSlug != old.slug || nextSource != old.source)) throw StateError('Close the workspace before changing its root or route');
    final next = old.copyWith(
      name: name?.trim(),
      slug: nextSlug,
      source: nextSource,
      visible: visible,
      allowUpload: nextSource.kind == WorkspaceSourceKind.androidTree && nextSource != old.source ? false : old.allowUpload,
      generation: old.generation + 1,
    );
    return _replace(next, root: _state.verifiedLocators[id]);
  });

  /// Changing browser writes advances the generation and needs a server acknowledgement.
  Future<DirectoryWorkspace> setAllowUpload(String id, bool value) => _mutate(() async {
    final old = _entry(id);
    if (value) await writeProbe(old.source).timeout(probeTimeout);
    if (old.allowUpload == value) return old;
    return _replace(
      old.copyWith(allowUpload: value, generation: old.generation + 1),
      root: _state.verifiedLocators[id],
    );
  });

  /// Explicit nullable update: null removes protection, rather than keeping it.
  Future<DirectoryWorkspace> setPassword(String id, String? verifier) => _mutate(() async {
    WorkspaceCatalogCodec.validatePasswordHash(verifier);
    final old = _entry(id);
    if (old.passwordHash == verifier) return old;
    return _replace(
      old.copyWith(passwordHash: verifier, generation: old.generation + 1),
      root: _state.verifiedLocators[id],
    );
  });

  Future<DirectoryWorkspace> enable(String id) => _mutate(() async {
    final old = _entry(id);
    final result = await _probe(old);
    return _replace(
      old.copyWith(enabled: result.isValid, invalidReason: result.invalidReason, generation: old.generation + 1),
      root: result.verifiedLocator,
    );
  });

  /// Explicit user-confirmed selection only. Each entry retains its own access,
  /// visibility and upload policy; stale confirmation never changes a new config.
  /// Failures are per entry, and closing entries never stops the listener itself.
  Future<List<WorkspaceBatchResult>> setEnabledBatch(List<DirectoryWorkspace> selection, bool enabled) {
    final snapshots = List<DirectoryWorkspace>.unmodifiable(selection);
    return _mutate(() async {
      if (snapshots.length > 128 || snapshots.map((entry) => entry.id).toSet().length != snapshots.length) {
        throw ArgumentError('Invalid workspace selection');
      }
      final results = <WorkspaceBatchResult>[];
      for (final selected in snapshots) {
        _checkAlive();
        final matches = _state.entries.where((entry) => entry.id == selected.id);
        if (matches.isEmpty || matches.first.generation != selected.generation) {
          results.add(WorkspaceBatchResult(selected.id, selected.name, WorkspaceBatchOutcome.changed));
          continue;
        }
        final old = matches.first;
        if (!enabled && !old.enabled && old.invalidReason == null) {
          results.add(WorkspaceBatchResult(old.id, old.name, WorkspaceBatchOutcome.applied));
          continue;
        }
        try {
          final probe = enabled ? await _probe(old) : null;
          if (enabled && old.enabled && probe!.isValid && probe.verifiedLocator == _state.verifiedLocators[old.id]) {
            // Rechecked authority, but do not churn healthy active generations.
            results.add(WorkspaceBatchResult(old.id, old.name, WorkspaceBatchOutcome.applied));
            continue;
          }
          final next = old.copyWith(
            enabled: enabled && probe!.isValid,
            invalidReason: probe?.invalidReason,
            generation: old.generation + 1,
          );
          await _replace(next, root: probe?.verifiedLocator);
          results.add(
            WorkspaceBatchResult(old.id, old.name, enabled && !probe!.isValid ? WorkspaceBatchOutcome.invalid : WorkspaceBatchOutcome.applied),
          );
        } catch (_) {
          results.add(WorkspaceBatchResult(old.id, old.name, WorkspaceBatchOutcome.failed));
        }
      }
      return List.unmodifiable(results);
    });
  }

  /// Check repairs without re-enabling a manually closed/invalid workspace.
  Future<DirectoryWorkspace> validate(String id) => _mutate(() async {
    final old = _entry(id);
    final result = await _probe(old);
    return _replace(
      old.copyWith(enabled: old.enabled && result.isValid, invalidReason: result.invalidReason, generation: old.generation + 1),
      root: result.verifiedLocator,
    );
  });

  Future<DirectoryWorkspace> disable(String id) => _mutate(() async {
    final old = _entry(id);
    if (!old.enabled && old.invalidReason == null) return old;
    return _replace(old.copyWith(enabled: false, invalidReason: null, generation: old.generation + 1));
  });

  Future<ApprovedWorkspaceSource> approveSource({required String name, required WorkspaceSource source}) => _mutate(() async {
    final approval = ApprovedWorkspaceSource(id: _newId(), name: name.trim(), source: source);
    await _commit(_state.entries, _state.verifiedLocators, approvedSources: [..._state.approvedSources, approval]);
    return approval;
  });

  Future<void> revokeSource(String id) => _mutate(() async {
    await _commit(_state.entries, _state.verifiedLocators, approvedSources: _state.approvedSources.where((source) => source.id != id).toList());
  });

  ApprovedWorkspaceSource _approved(String id) => _state.approvedSources.firstWhere(
    (source) => source.id == id,
    orElse: () => throw const WorkspaceManagementException(WorkspaceManagementFailure.sourceNotApproved),
  );

  Future<List<ApprovedWorkspaceSource>> managementSources({required Future<bool> Function() claim}) => _mutate(() async {
    if (!await claim()) throw const WorkspaceManagementException(WorkspaceManagementFailure.claimRejected);
    return List.unmodifiable(_state.approvedSources);
  });

  Future<DirectoryWorkspace> managementCreate({
    required String sourceId,
    required String name,
    required String slug,
    required Future<bool> Function() claim,
    bool visible = true,
    bool allowUpload = false,
  }) => _mutate(() async {
    final source = _approved(sourceId).source;
    final entry = DirectoryWorkspace(
      id: _newId(),
      name: name.trim(),
      slug: WorkspaceCatalogCodec.normalizeSlug(slug),
      source: source,
      enabled: false,
      visible: visible,
      allowUpload: allowUpload,
      generation: 1,
    );
    WorkspaceCatalogCodec.validateAll([..._state.entries, entry]);
    if (!await claim()) throw const WorkspaceManagementException(WorkspaceManagementFailure.claimRejected);
    if (allowUpload) await writeProbe(source).timeout(probeTimeout);
    await _commit([..._state.entries, entry], _state.verifiedLocators);
    return entry;
  });

  /// Remote reads share the mutation queue so a stale pre-queue snapshot cannot
  /// race a persisted local edit. The server grant is claimed only at execution.
  Future<List<DirectoryWorkspace>> managementSnapshot({required Future<bool> Function() claim}) => _mutate(() async {
    if (!await claim()) throw const WorkspaceManagementException(WorkspaceManagementFailure.claimRejected);
    _checkAlive();
    return List.unmodifiable(_state.entries);
  });

  /// Compare-and-swap is inside the same queue as local UI mutations. Claim is
  /// checked immediately before this accepted mutation starts; a source probe
  /// may finish after a later request cancellation, but never changes its source.
  Future<DirectoryWorkspace> manage({
    required String id,
    required int generation,
    required WorkspaceManagementAction action,
    required Future<bool> Function() claim,
    String? name,
    bool? visible,
    bool? allowUpload,
    String? sourceId,
    String? slug,
    Future<String?> Function()? passwordVerifier,
  }) => _mutate(() async {
    final matches = _state.entries.where((entry) => entry.id == id);
    if (matches.isEmpty) throw const WorkspaceManagementException(WorkspaceManagementFailure.notFound);
    final old = matches.single;
    if (old.generation != generation) throw const WorkspaceManagementException(WorkspaceManagementFailure.staleGeneration);
    if (action != WorkspaceManagementAction.update && (name != null || visible != null || allowUpload != null)) {
      throw const FormatException('Unexpected workspace update fields');
    }
    WorkspaceSource? source;
    if (action == WorkspaceManagementAction.configure) {
      if (old.enabled) throw const WorkspaceManagementException(WorkspaceManagementFailure.mustBeClosed);
      if (sourceId == null && slug == null) throw const FormatException('Empty source update');
      source = sourceId == null ? old.source : _approved(sourceId).source;
      WorkspaceCatalogCodec.validateAll([
        for (final entry in _state.entries)
          if (entry.id == id) old.copyWith(source: source, slug: slug == null ? old.slug : WorkspaceCatalogCodec.normalizeSlug(slug)) else entry,
      ]);
    } else if (sourceId != null || slug != null) {
      throw const FormatException('Unexpected source update');
    }
    if ((action == WorkspaceManagementAction.password) != (passwordVerifier != null)) throw const FormatException('Invalid password update');
    if (!await claim()) throw const WorkspaceManagementException(WorkspaceManagementFailure.claimRejected);
    _checkAlive();
    if (allowUpload == true) await writeProbe(old.source).timeout(probeTimeout);
    switch (action) {
      case WorkspaceManagementAction.configure:
        return _replace(
          old.copyWith(
            source: source,
            allowUpload: source?.kind == WorkspaceSourceKind.androidTree && source != old.source ? false : old.allowUpload,
            slug: slug == null ? old.slug : WorkspaceCatalogCodec.normalizeSlug(slug),
            invalidReason: null,
            generation: old.generation + 1,
          ),
        );
      case WorkspaceManagementAction.password:
        final verifier = await passwordVerifier!();
        WorkspaceCatalogCodec.validatePasswordHash(verifier);
        return _replace(
          old.copyWith(passwordHash: verifier, generation: old.generation + 1),
          root: _state.verifiedLocators[id],
        );
      case WorkspaceManagementAction.destroy:
        await _commit(_state.entries.where((entry) => entry.id != id).toList(), {..._state.verifiedLocators}..remove(id));
        return old;
      case WorkspaceManagementAction.update:
        final next = old.copyWith(name: name?.trim(), visible: visible, allowUpload: allowUpload, generation: old.generation + 1);
        return _replace(next, root: _state.verifiedLocators[id]);
      case WorkspaceManagementAction.disable:
        return _replace(old.copyWith(enabled: false, invalidReason: null, generation: old.generation + 1));
      case WorkspaceManagementAction.enable:
      case WorkspaceManagementAction.validate:
        final result = await _probe(old);
        return _replace(
          old.copyWith(
            enabled: result.isValid && (action == WorkspaceManagementAction.enable || old.enabled),
            invalidReason: result.invalidReason,
            generation: old.generation + 1,
          ),
          root: result.verifiedLocator,
        );
    }
  });

  /// Remove configuration only. Never deletes any filesystem content.
  Future<void> destroy(String id) => _mutate(() async {
    if (!_state.entries.any((entry) => entry.id == id)) return;
    await _commit(_state.entries.where((entry) => entry.id != id).toList(), {..._state.verifiedLocators}..remove(id));
  });
}
