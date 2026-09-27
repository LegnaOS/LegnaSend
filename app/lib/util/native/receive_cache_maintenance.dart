import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart' as native;
import 'package:localsend_isolates/util/ios_receive_scope.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _logger = Logger('ReceiveCacheMaintenance');

// Policy must be synchronized before automatic destructive maintenance starts.
bool _automaticCleanupAllowed = false;
void setAutomaticReceiveCacheCleanupAllowed(bool allowed) => _automaticCleanupAllowed = allowed;

/// Configure before listening; persistent metadata is separate from temp caches.
Future<void> initializeReceiveCacheMaintenance({
  required bool portable,
  Future<String> Function()? supportDirectory,
  String Function()? portableSettingsPath,
  Future<void> Function(String)? configure,
}) async {
  try {
    final directory = portable
        ? File((portableSettingsPath ?? () => SharedPreferencesPortable().getPath())()).parent.path
        : await (supportDirectory ?? () async => (await getApplicationSupportDirectory()).path)();
    await (configure ?? (path) => native.configureReceiveCacheRegistry(directory: path))(p.join(directory, '.legnasend-receive-registry'));
  } catch (e, st) {
    // Keep the existing in-process receiver available, but never invent a
    // replacement registry in Downloads or delete unregistered files.
    _logger.warning('Receive cache registration unavailable; startup cleanup will retain unregistered files', e, st);
  }
}

/// A bounded per-entry result. A display name is local UI metadata, never a
/// path; API callers should use [toJson] with includeDisplayName set to false.
@immutable
class ReceiveCacheEntry {
  final String id, sourceKind, disposition, reason;
  final String? fileName;
  final int plannedBytes, unlinkedBytes;
  const ReceiveCacheEntry({
    required this.id,
    required this.sourceKind,
    required this.disposition,
    required this.reason,
    this.fileName,
    this.plannedBytes = 0,
    this.unlinkedBytes = 0,
  });

  static final _idPattern = RegExp(r'^[a-f0-9]{64}$');

  factory ReceiveCacheEntry.parse(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException('Invalid cache entry');
    String text(String key) {
      final text = value[key];
      if (text is! String || text.isEmpty || text.length > 2048) throw FormatException('Invalid entry $key');
      return text;
    }

    int bytes(String key) {
      final bytes = value[key];
      if (bytes is! int || bytes < 0) throw FormatException('Invalid entry $key');
      return bytes;
    }

    if (!_idPattern.hasMatch(text('id'))) throw const FormatException('Invalid opaque cache entry identity');
    final name = value['fileName'];
    if (name != null && (name is! String || name.length > 2048)) throw const FormatException('Invalid entry display name');
    final disposition = text('disposition');
    if (!{'candidate', 'removed', 'retired', 'retained', 'active', 'failed'}.contains(disposition)) {
      throw const FormatException('Invalid entry disposition');
    }
    final sourceKind = text('sourceKind');
    if (!{'unknown', 'nativeReceive', 'directoryUpload'}.contains(sourceKind)) throw const FormatException('Invalid entry source kind');
    return ReceiveCacheEntry(
      id: text('id'),
      sourceKind: sourceKind,
      disposition: disposition,
      reason: text('reason'),
      fileName: name as String?,
      plannedBytes: bytes('plannedBytes'),
      unlinkedBytes: bytes('unlinkedBytes'),
    );
  }

  Map<String, dynamic> toJson({bool includeDisplayName = true}) => {
    'id': id,
    'sourceKind': sourceKind,
    'disposition': disposition,
    'reason': reason,
    if (includeDisplayName) 'fileName': fileName,
    'plannedBytes': plannedBytes,
    'unlinkedBytes': unlinkedBytes,
  };
}

/// Counts are logical records/file lengths, never a claim about free disk space.
@immutable
class ReceiveCacheCleanupReport {
  final int examined, removedFiles, removedRecords, plannedBytes, unlinkedBytes, active, retained, failed, batches;
  final bool budgetReached, interrupted;
  final Map<String, int> reasons;
  final List<ReceiveCacheEntry> entries;
  final bool inspection, entriesTruncated;

  const ReceiveCacheCleanupReport({
    this.examined = 0,
    this.removedFiles = 0,
    this.removedRecords = 0,
    this.plannedBytes = 0,
    this.unlinkedBytes = 0,
    this.active = 0,
    this.retained = 0,
    this.failed = 0,
    this.batches = 0,
    this.budgetReached = false,
    this.interrupted = false,
    this.reasons = const {},
    this.entries = const [],
    this.inspection = false,
    this.entriesTruncated = false,
  });

  bool get needsAttention => interrupted || failed > 0 || retained > 0;

  factory ReceiveCacheCleanupReport.parse(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic>) throw const FormatException('Invalid cleanup report');
    int count(String key) {
      final value = json[key] ?? 0;
      if (value is! int || value < 0) throw FormatException('Invalid cleanup count: $key');
      return value;
    }

    if (json['budgetReached'] != null && json['budgetReached'] is! bool) throw const FormatException('Invalid cleanup budget');
    final entries = json['entries'] ?? const [];
    if (entries is! List || entries.length > 4096) throw const FormatException('Invalid cache entries');
    if (json['entriesTruncated'] != null && json['entriesTruncated'] is! bool) throw const FormatException('Invalid entry truncation flag');
    if (json['inspection'] != null && json['inspection'] is! bool) throw const FormatException('Invalid inspection mode');
    final reasons = json['reasons'] ?? <String, dynamic>{};
    if (reasons is! Map<String, dynamic> || reasons.values.any((v) => v is! int || v < 0)) {
      throw const FormatException('Invalid cleanup reasons');
    }
    return ReceiveCacheCleanupReport(
      examined: count('examined'),
      removedFiles: count('removedFiles'),
      removedRecords: count('removedRecords'),
      plannedBytes: count('plannedBytes'),
      unlinkedBytes: count('unlinkedBytes'),
      active: count('active'),
      retained: count('retained'),
      failed: count('failed'),
      budgetReached: json['budgetReached'] == true,
      batches: 1,
      reasons: Map.unmodifiable(reasons.cast<String, int>()),
      entries: List.unmodifiable(entries.map(ReceiveCacheEntry.parse)),
      inspection: json['inspection'] == true,
      entriesTruncated: json['entriesTruncated'] == true,
    );
  }

  ReceiveCacheCleanupReport add(ReceiveCacheCleanupReport other) => ReceiveCacheCleanupReport(
    examined: examined + other.examined,
    removedFiles: removedFiles + other.removedFiles,
    removedRecords: removedRecords + other.removedRecords,
    plannedBytes: plannedBytes + other.plannedBytes,
    unlinkedBytes: unlinkedBytes + other.unlinkedBytes,
    active: active + other.active,
    retained: retained + other.retained,
    failed: failed + other.failed,
    batches: batches + other.batches,
    budgetReached: other.budgetReached,
    interrupted: interrupted || other.interrupted,
    inspection: inspection || other.inspection,
    entriesTruncated: entriesTruncated || other.entriesTruncated,
    entries: List.unmodifiable([...entries, ...other.entries]),
    reasons: Map.unmodifiable({
      for (final key in {...reasons.keys, ...other.reasons.keys}) key: (reasons[key] ?? 0) + (other.reasons[key] ?? 0),
    }),
  );
}

final receiveCacheInspectionBusy = ValueNotifier(false);
Future<ReceiveCacheCleanupReport>? _runningInspection;
bool _inspectionManual = false;

/// Reads native-path registration and eligibility only: no unlink, retirement,
/// Android provider reconciliation, probing peers or transfer cancellation.
/// Repeated bounded calls advance a dedicated cursor independent of cleanup.
Future<ReceiveCacheCleanupReport> inspectRegisteredReceiveCaches({
  Future<String> Function()? inspect,
  bool manual = false,
  int maxBatches = 1,
  IosReceiveCacheMaintenance? iosMaintenance,
}) {
  if (maxBatches < 1 || maxBatches > 16) throw ArgumentError.value(maxBatches, 'maxBatches');
  if (_runningInspection != null) {
    if (_inspectionManual == manual) return _runningInspection!;
    return _runningInspection!.then(
      (_) => inspectRegisteredReceiveCaches(inspect: inspect, manual: manual, maxBatches: maxBatches, iosMaintenance: iosMaintenance),
    );
  }
  _inspectionManual = manual;
  receiveCacheInspectionBusy.value = true;
  return _runningInspection = (() async {
    await Future<void>.value();
    var total = const ReceiveCacheCleanupReport(inspection: true);
    try {
      for (var batch = 0; batch < maxBatches; batch++) {
        final raw =
            await (inspect ?? () => manual ? native.inspectReceiveCacheRegistryNow(limit: 4096) : native.inspectReceiveCacheRegistry(limit: 4096))();
        final report = ReceiveCacheCleanupReport.parse(raw);
        _validateInspection(report);
        total = total.add(report);
        if (!report.budgetReached) break;
      }
    } catch (error, stack) {
      _logger.warning('Receive cache inspection incomplete; no cleanup was requested', error, stack);
      total = total.add(ReceiveCacheCleanupReport(inspection: true, interrupted: true, budgetReached: total.budgetReached));
    }
    try {
      if (iosMaintenance != null || Platform.isIOS) {
        total = await _maintainIosReceiveCaches(total, iosMaintenance ?? IosReceiveCacheMaintenance.native(), maxBatches, manual, true);
      }
    } finally {
      _runningInspection = null;
      receiveCacheInspectionBusy.value = false;
    }
    return total;
  })();
}

final receiveCacheCleanupBusy = ValueNotifier(false);
Future<ReceiveCacheCleanupReport>? _runningCleanup;
bool _cleanupManual = false;

/// Startup, settings and temporary-cache cleanup share one bounded scan.
/// Closing a dialog does not cancel cleanup or stop the transfer server.
Future<ReceiveCacheCleanupReport> cleanRegisteredReceiveCaches({
  Future<String> Function()? cleanup,
  bool manual = false,
  int maxBatches = 16,
  Future<Map<String, dynamic>> Function()? providerCleanup,
  IosReceiveCacheMaintenance? iosMaintenance,
}) {
  if (maxBatches < 1 || maxBatches > 16) throw ArgumentError.value(maxBatches, 'maxBatches');
  if (_runningCleanup != null) {
    if (_cleanupManual == manual) return _runningCleanup!;
    return _runningCleanup!.then(
      (_) => cleanRegisteredReceiveCaches(
        cleanup: cleanup,
        manual: manual,
        maxBatches: maxBatches,
        providerCleanup: providerCleanup,
        iosMaintenance: iosMaintenance,
      ),
    );
  }
  _cleanupManual = manual;
  final operation = _cleanRegisteredReceiveCaches(cleanup, maxBatches, providerCleanup, manual, iosMaintenance);
  _runningCleanup = operation;
  receiveCacheCleanupBusy.value = true;
  return operation;
}

Future<ReceiveCacheCleanupReport> _cleanRegisteredReceiveCaches(
  Future<String> Function()? cleanup,
  int maxBatches,
  Future<Map<String, dynamic>> Function()? providerCleanup,
  bool manual,
  IosReceiveCacheMaintenance? iosMaintenance,
) async {
  // Yield before publishing state so even a synchronous injected error cannot
  // leave the shared operation permanently busy.
  await Future<void>.value();
  var total = const ReceiveCacheCleanupReport();
  try {
    try {
      for (var batch = 0; batch < maxBatches; batch++) {
        if (!manual && cleanup == null && !_automaticCleanupAllowed) {
          total = total.add(const ReceiveCacheCleanupReport(interrupted: true, reasons: {'retention_unavailable': 1}));
          break;
        }
        final raw =
            await (cleanup ?? () => manual ? native.cleanupReceiveCacheRegistryNow(limit: 4096) : native.cleanupReceiveCacheRegistry(limit: 4096))();
        final report = ReceiveCacheCleanupReport.parse(raw);
        total = total.add(report);
        _logger.info('Registered receive cache cleanup: examined=${report.examined}, removed=${report.removedFiles}, failed=${report.failed}');
        if (!report.budgetReached) break;
      }
    } catch (e, st) {
      _logger.warning('Registered receive cache cleanup incomplete; files retained', e, st);
      total = total.add(ReceiveCacheCleanupReport(interrupted: true, budgetReached: total.budgetReached));
    }
    if (iosMaintenance != null || Platform.isIOS) {
      total = await _maintainIosReceiveCaches(total, iosMaintenance ?? IosReceiveCacheMaintenance.native(), maxBatches, manual, false);
    }
    if (providerCleanup != null || Platform.isAndroid) {
      try {
        final report = await (providerCleanup ?? () => reconcileSafReceiveTransactions())();
        int count(String key) {
          final value = report[key];
          if (value is! int || value < 0) throw FormatException('Invalid provider cleanup count: $key');
          return value;
        }

        final reasons = report['reasons'];
        if (report['truncated'] is! bool || reasons is! List || reasons.any((v) => v is! String)) {
          throw const FormatException('Invalid provider cleanup report');
        }
        final active = count('activeTransactions');
        final retained = count('retainedTransactions');
        final publications = report.containsKey('publicationReconciled') ? count('publicationReconciled') : 0;
        if (publications > count('examined')) throw const FormatException('Invalid publication reconciliation count');
        final stagingDeleted = report.containsKey('publishedStagingDeleted') ? count('publishedStagingDeleted') : 0;
        if (stagingDeleted > count('examined')) throw const FormatException('Invalid published staging deletion count');
        total = total.add(
          ReceiveCacheCleanupReport(
            examined: count('examined'),
            // The scan snapshot precedes the separately acknowledged recovery deletions.
            removedFiles:
                count('deletedDocuments') + (report.containsKey('recoveryDeletedCaches') ? count('recoveryDeletedCaches') : 0) + stagingDeleted,
            removedRecords: count('removedRecords'),
            active: active,
            retained: (retained - active).clamp(0, retained),
            batches: 1,
            budgetReached: total.budgetReached || report['truncated'] == true,
            reasons: {
              for (final code in reasons.cast<String>().toSet())
                if (code != 'PUBLICATION_RECONCILED' && code != 'PUBLISHED_STAGING_DELETED') 'SAF_$code': reasons.where((v) => v == code).length,
              if (publications > 0) 'SAF_PUBLICATION_RECONCILED': publications,
              if (stagingDeleted > 0) 'SAF_PUBLISHED_STAGING_DELETED': stagingDeleted,
              if (count('publishedReceipts') > 0) 'SAF_PUBLISHED_RECEIPT': count('publishedReceipts'),
            },
          ),
        );
      } catch (error, stack) {
        _logger.warning('Provider receive cleanup retained for reconciliation', error, stack);
        total = total.add(ReceiveCacheCleanupReport(interrupted: true, budgetReached: total.budgetReached));
      }
    }
  } finally {
    _runningCleanup = null;
    receiveCacheCleanupBusy.value = false;
  }
  return total;
}

/// The generic mobile temp cleaner must not race registered/active transfers.
bool shouldPreserveReceiveTemporaryName(String name) => name.startsWith('.legnasend-receive-') || name.toLowerCase().endsWith('.ls');

/// Injectable boundary; the production worker receives only a currently leased
/// root, never a remembered path without its coordinated native accessor.
class IosReceiveCacheMaintenance {
  final Future<List<String>> Function() listRoots;
  final Future<IosReceiveScopeLease?> Function(String) acquire;
  final Future<String> Function(String directory, {required int limit, required bool inspection, required bool force}) maintain;

  const IosReceiveCacheMaintenance({required this.listRoots, required this.acquire, required this.maintain});

  factory IosReceiveCacheMaintenance.native() => IosReceiveCacheMaintenance(
    listRoots: listIosGrantedReceivePaths,
    acquire: acquireIosReceiveMaintenanceScope,
    maintain: (directory, {required limit, required inspection, required force}) => native.maintainReceiveCacheRegistryInScope(
      directory: directory,
      limit: limit,
      inspection: inspection,
      force: force,
    ),
  );
}

final _iosMaintenanceCursor = <bool, int>{};

void _validateInspection(ReceiveCacheCleanupReport report) {
  if (!report.inspection ||
      report.removedFiles != 0 ||
      report.removedRecords != 0 ||
      report.unlinkedBytes != 0 ||
      report.entries.any((entry) => entry.unlinkedBytes != 0 || {'removed', 'retired'}.contains(entry.disposition))) {
    throw const FormatException('Inspection must never report removals');
  }
}

/// Replace prior non-destructive observations only when opaque identities match.
/// Counts absent from a truncated detail list remain conservative, never guessed.
ReceiveCacheCleanupReport _mergeScopedReport(ReceiveCacheCleanupReport total, ReceiveCacheCleanupReport next) {
  final ids = next.entries.map((entry) => entry.id).toSet();
  final replaced = total.entries
      .where(
        (entry) => ids.contains(entry.id) && entry.unlinkedBytes == 0 && {'retained', 'active', 'candidate'}.contains(entry.disposition),
      )
      .toSet();
  final reasons = Map<String, int>.of(total.reasons);
  for (final entry in replaced) {
    final remaining = (reasons[entry.reason] ?? 0) - 1;
    if (remaining <= 0) {
      reasons.remove(entry.reason);
    } else {
      reasons[entry.reason] = remaining;
    }
  }
  int subtract(int count, int removed) => (count - removed).clamp(0, count);
  return ReceiveCacheCleanupReport(
    examined: subtract(total.examined, replaced.length),
    removedFiles: total.removedFiles,
    removedRecords: total.removedRecords,
    plannedBytes: subtract(total.plannedBytes, replaced.fold(0, (sum, entry) => sum + entry.plannedBytes)),
    unlinkedBytes: total.unlinkedBytes,
    active: subtract(total.active, replaced.where((entry) => entry.disposition == 'active').length),
    retained: subtract(total.retained, replaced.where((entry) => entry.disposition == 'retained').length),
    failed: total.failed,
    batches: total.batches,
    budgetReached: total.budgetReached,
    interrupted: total.interrupted,
    reasons: reasons,
    entries: total.entries.where((entry) => !replaced.contains(entry)).toList(),
    inspection: total.inspection,
    entriesTruncated: total.entriesTruncated,
  ).add(next);
}

Future<ReceiveCacheCleanupReport> _maintainIosReceiveCaches(
  ReceiveCacheCleanupReport total,
  IosReceiveCacheMaintenance operations,
  int maxBatches,
  bool manual,
  bool inspection,
) async {
  ReceiveCacheCleanupReport problem(String reason, {bool failed = false}) => ReceiveCacheCleanupReport(
    inspection: inspection,
    interrupted: true,
    failed: failed ? 1 : 0,
    budgetReached: total.budgetReached,
    reasons: {reason: 1},
  );
  // Even injected/native-scan overrides must not bypass automatic policy here.
  if (!inspection && !manual && !_automaticCleanupAllowed) {
    if (!total.reasons.containsKey('retention_unavailable')) total = total.add(problem('retention_unavailable'));
    return total;
  }
  List<String> roots;
  try {
    roots = await operations.listRoots();
    if (roots.length > 128 || roots.any((path) => !p.posix.isAbsolute(path) || path.contains('\u0000'))) {
      throw const FormatException('Invalid iOS maintenance roots');
    }
    roots = roots.toSet().toList();
  } catch (error, stack) {
    _logger.warning('Coordinated receive cache roots unavailable', error, stack);
    return total.add(problem('ios_scope_list_failed', failed: true));
  }
  if (roots.isEmpty) return total;
  final pending = roots.toSet();
  var cursor = (_iosMaintenanceCursor[inspection] ?? 0) % roots.length;
  var remainingBudget = total.budgetReached;
  // At most maxBatches root acquisitions/worker calls, including denied roots.
  // Advance across calls so a busy/revoked early root cannot starve later roots.
  for (var attempt = 0; attempt < maxBatches && pending.isNotEmpty; attempt++) {
    while (!pending.contains(roots[cursor])) {
      cursor = (cursor + 1) % roots.length;
    }
    final root = roots[cursor];
    cursor = (cursor + 1) % roots.length;
    _iosMaintenanceCursor[inspection] = cursor;
    IosReceiveScopeLease? lease;
    var releaseFailed = false;
    try {
      if (!inspection && !manual && !_automaticCleanupAllowed) {
        total = total.add(problem('retention_unavailable'));
        break;
      }
      lease = await operations.acquire(root);
      // The list contains external bookmarks. A null sandbox classification is
      // not permission to run an external scoped worker against that list entry.
      if (lease == null || lease.path != root) throw const FormatException('Missing coordinated maintenance scope');
      if (!inspection && !manual && !_automaticCleanupAllowed) {
        total = total.add(problem('retention_unavailable'));
        break;
      }
      final report = ReceiveCacheCleanupReport.parse(await operations.maintain(root, limit: 4096, inspection: inspection, force: manual));
      if (inspection) _validateInspection(report);
      if (report.inspection != inspection) throw const FormatException('Unexpected scoped maintenance mode');
      total = _mergeScopedReport(total, report);
      if (!report.budgetReached) pending.remove(root);
    } catch (error, stack) {
      _logger.warning('Coordinated receive cache maintenance retained for retry', error, stack);
      final busy = error is PlatformException && error.code == 'receiveGrantBusy';
      total = total.add(problem(busy ? 'ios_scope_busy' : 'ios_scoped_maintenance_failed', failed: !busy));
      pending.remove(root);
    } finally {
      if (lease != null) {
        try {
          // No timeout/cancel: native acknowledges only after accessor drain.
          await lease.release();
        } catch (error, stack) {
          _logger.warning('Coordinated receive cache release not acknowledged', error, stack);
          total = total.add(problem('ios_scope_release_failed', failed: true));
          releaseFailed = true;
        }
      }
    }
    // Unknown native release state must not lead to more acquisitions this pass.
    if (releaseFailed) break;
  }
  remainingBudget = remainingBudget || pending.isNotEmpty;
  return total.add(ReceiveCacheCleanupReport(inspection: inspection, budgetReached: remainingBudget));
}
