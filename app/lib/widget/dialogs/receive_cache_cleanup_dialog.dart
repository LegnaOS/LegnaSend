import 'package:flutter/material.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:localsend_app/widget/dialogs/receive_cache_cleanup_strings.dart';

/// In-app confirmation and results. No listener/server lifecycle operations.
class ReceiveCacheCleanupDialog extends StatefulWidget {
  final String locale;
  final Future<ReceiveCacheCleanupReport> Function()? cleanup;
  final Future<ReceiveCacheCleanupReport> Function()? inspect;
  const ReceiveCacheCleanupDialog({super.key, required this.locale, this.cleanup, this.inspect});

  @override
  State<ReceiveCacheCleanupDialog> createState() => _ReceiveCacheCleanupDialogState();
}

class _ReceiveCacheCleanupDialogState extends State<ReceiveCacheCleanupDialog> {
  ReceiveCacheCleanupReport? _report;
  bool _working = false;

  Future<void> _clean() => _run(false);
  Future<void> _inspect() => _run(true);

  Future<void> _run(bool inspection) async {
    if (_working) return;
    setState(() => _working = true);
    ReceiveCacheCleanupReport report;
    try {
      report = await (inspection
          ? (widget.inspect ?? () => inspectRegisteredReceiveCaches(manual: true))
          : (widget.cleanup ?? () => cleanRegisteredReceiveCaches(manual: true)))();
    } catch (_) {
      report = ReceiveCacheCleanupReport(interrupted: true, inspection: inspection);
    }
    if (!mounted) return;
    setState(() {
      _report = report;
      _working = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ReceiveCacheCleanupStrings(widget.locale);
    return ListenableBuilder(
      listenable: Listenable.merge([receiveCacheCleanupBusy, receiveCacheInspectionBusy]),
      builder: (context, _) {
        final busy = _working || receiveCacheCleanupBusy.value || receiveCacheInspectionBusy.value;
        final report = _report;
        return AlertDialog(
          title: Text(s.title),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.description),
                if (busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(s.busy, semanticsLabel: s.busy),
                ],
                if (report != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      report.needsAttention ? s.partial : (report.budgetReached ? s.bounded : (report.inspection ? s.inspected : s.completed)),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (report.inspection) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.inspectionNote)),
                  if (report.interrupted) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.interrupted)),
                  if (report.budgetReached) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.more)),
                  const SizedBox(height: 8),
                  for (final row in [
                    (s.examined, report.examined),
                    (s.files, report.removedFiles),
                    (s.records, report.removedRecords),
                    (s.plannedBytes, report.plannedBytes),
                    (s.bytes, report.unlinkedBytes),
                    (s.active, report.active),
                    (s.retained, report.retained),
                    (s.failed, report.failed),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Text(row.$1)),
                          const SizedBox(width: 12),
                          Flexible(child: Text('${row.$2}', textAlign: TextAlign.end)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(s.bytesNote, style: Theme.of(context).textTheme.bodySmall),
                  if (report.entries.isNotEmpty) ...[
                    const Divider(height: 24),
                    Text('${s.details} · ${report.entries.length}', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 240,
                      child: ListView.separated(
                        key: const ValueKey('receive-cache-entries'),
                        primary: false,
                        itemCount: report.entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 16),
                        itemBuilder: (context, index) {
                          final entry = report.entries[index];
                          final color = Theme.of(context).colorScheme;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.fileName ?? '${s.unknownEntry} · ${entry.id.substring(0, entry.id.length.clamp(0, 12))}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  for (final label in [s.sourceKind(entry.sourceKind), s.disposition(entry.disposition)])
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: entry.disposition == 'failed' ? color.errorContainer : color.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        label,
                                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: entry.disposition == 'failed' ? color.onErrorContainer : color.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(s.reason(entry.reason), style: Theme.of(context).textTheme.bodySmall),
                              Text(s.entryBytes(entry.plannedBytes, entry.unlinkedBytes), style: Theme.of(context).textTheme.bodySmall),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                  if (report.reasons.isNotEmpty) ...[
                    const Divider(height: 24),
                    for (final reason in report.reasons.entries) Text('${s.reason(reason.key)} · ${reason.value}'),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.close)),
            TextButton(
              key: const ValueKey('receive-cache-inspect'),
              onPressed: busy ? null : _inspect,
              child: Text(report?.inspection == true && report!.budgetReached ? s.inspectNext : s.inspect),
            ),
            FilledButton(
              key: const ValueKey('receive-cache-clean'),
              onPressed: busy ? null : _clean,
              child: Text(report == null || report.inspection ? s.clean : (report.budgetReached ? s.resume : s.retry)),
            ),
          ],
        );
      },
    );
  }
}
