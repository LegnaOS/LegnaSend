import 'package:flutter/material.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/widget/dialogs/workspace_capture_cleanup_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Opening only observes prior maintenance. A cleanup requires this in-page action.
class WorkspaceCaptureCleanupDialog extends StatelessWidget {
  final String locale;
  const WorkspaceCaptureCleanupDialog({super.key, required this.locale});
  @override
  Widget build(BuildContext context) {
    final s = WorkspaceCaptureCleanupStrings(locale);
    final state = context.watch(workspaceCaptureMaintenanceProvider);
    final available = context.watch(workspaceCaptureStoreProvider) != null;
    final report = state.report;
    final attention = state.interrupted || (report?.failed ?? 0) > 0 || (report?.retained ?? 0) > 0;
    return AlertDialog(
      title: Text(s.title),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.description),
            if (!available) Padding(padding: const EdgeInsets.only(top: 12), child: Text(s.unavailable)),
            if (state.busy) ...[const SizedBox(height: 12), const LinearProgressIndicator(), Text(s.busy)],
            if (report != null || state.interrupted) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  state.interrupted
                      ? s.failed
                      : state.busy
                      ? s.busy
                      : attention
                      ? s.partial
                      : s.completed,
                ),
              ),
              if (report != null) ...[
                for (final (index, value) in [
                  report.examined,
                  report.removedStages,
                  report.removedFiles,
                  report.unlinkedBytes,
                  report.active,
                  report.retained,
                  report.failed,
                  state.batches,
                ].indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(s.rows[index])),
                        const SizedBox(width: 12),
                        Flexible(child: Text('$value', textAlign: TextAlign.end)),
                      ],
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 12),
            Text(s.note, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.close)),
        FilledButton(
          onPressed: !available || state.busy
              ? null
              : () async {
                  try {
                    await context.ref.notifier(workspaceCaptureStoreProvider).clean();
                  } catch (_) {
                    /* Provider retains failure and partial counts. */
                  }
                },
          child: Text(attention ? s.retry : s.clean),
        ),
      ],
    );
  }
}
