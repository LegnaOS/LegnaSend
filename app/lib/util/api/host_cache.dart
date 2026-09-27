import 'package:localsend_app/util/native/receive_cache_maintenance.dart';

/// Integration callers receive opaque identities and stable reasons, not names,
/// paths, SAF URIs, source contents or arbitrary filesystem deletion controls.
Future<Map<String, Object>> runHostCacheOperation(bool cleanup) async {
  final report = cleanup ? await cleanRegisteredReceiveCaches(maxBatches: 1) : await inspectRegisteredReceiveCaches();
  return {
    'examined': report.examined,
    'removedFiles': report.removedFiles,
    'removedRecords': report.removedRecords,
    'plannedBytes': report.plannedBytes,
    'unlinkedBytes': report.unlinkedBytes,
    'active': report.active,
    'retained': report.retained,
    'failed': report.failed,
    'budgetReached': report.budgetReached,
    'interrupted': report.interrupted,
    'entriesTruncated': report.entriesTruncated || report.entries.length > 128,
    'entries': [
      for (final entry in report.entries.take(128))
        {
          'id': entry.id,
          'sourceKind': entry.sourceKind,
          'disposition': entry.disposition,
          'reason': entry.reason,
          'plannedBytes': entry.plannedBytes,
          'unlinkedBytes': entry.unlinkedBytes,
        },
    ],
  };
}
