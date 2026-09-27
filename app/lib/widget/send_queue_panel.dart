import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/pages/settings/source_end_page.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/send_recovery_strings.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_app/util/source_end_strings.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A wrapping tag and explicit outcomes, including when no live session remains.
class SendRecoverySummary extends StatelessWidget {
  final SendJob job;
  const SendRecoverySummary({required this.job});

  @override
  Widget build(BuildContext context) {
    final labels = SendRecoveryStrings(Translations.of(context).$meta.locale);
    final completed = job.completedIndices.where((i) => i >= 0 && i < job.files.length && !job.skippedIndices.contains(i)).length;
    final skipped = job.skippedIndices.where((i) => i >= 0 && i < job.files.length).length;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: colors.secondaryContainer, borderRadius: BorderRadius.circular(8)),
          child: Text(
            job.recoveryChecking
                ? labels.checking
                : switch (job.status) {
                    SendJobStatus.succeeded => labels.completed,
                    SendJobStatus.running => labels.continuing,
                    SendJobStatus.queued => labels.queued,
                    _ => labels.restored,
                  },
            style: TextStyle(color: colors.onSecondaryContainer),
          ),
        ),
        Text(labels.summary(completed, skipped, job.files.length - completed - skipped)),
        if (job.recoveryIssue != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(labels.issue(job.recoveryIssue!), style: TextStyle(color: colors.error)),
          ),
      ],
    );
  }
}

class SendQueuePanel extends StatelessWidget {
  const SendQueuePanel();

  @override
  Widget build(BuildContext context) {
    final labels = SendRouteStrings(Translations.of(context).$meta.locale);
    final recovery = SendRecoveryStrings(Translations.of(context).$meta.locale);
    final jobs = context.watch(sendQueueProvider);
    final recoveryIssue = context.watch(sendRecoveryIssueProvider);
    final notices = context.watch(sourceEndProvider);
    final sourceLabels = SourceEndStrings(LocaleSettings.currentLocale.languageTag);
    if (jobs.isEmpty && recoveryIssue == null && notices.isEmpty) return const SizedBox.shrink();
    final sessions = context.watch(sendProvider);
    final queue = context.ref.notifier(sendQueueProvider);
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text('${t.sendQueue.title} (${jobs.where((j) => !j.terminal).length}/${jobs.length})'),
      children: [
        if (notices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: StatusTag(
              label: '${sourceLabels.title} · ${notices.length}',
              icon: Icons.receipt_long_outlined,
              onTap: () async {
                await context.push(() => const SourceEndPage());
              },
            ),
          ),
        if (recoveryIssue != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(recovery.issue(recoveryIssue), key: const ValueKey('send-recovery-global-issue')),
          ),
        for (final job in jobs.reversed)
          Padding(
            key: ValueKey('send-queue-${job.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${job.target.alias} · ${t.sendQueue.files(n: job.files.length)}', style: Theme.of(context).textTheme.titleMedium),
                if (job.restored)
                  SendRecoverySummary(job: job)
                else
                  Text(
                    [
                      switch (job.status) {
                        SendJobStatus.queued => t.sendQueue.queued,
                        SendJobStatus.running => sessions[job.id]?.status == SessionStatus.waiting ? t.sendPage.waiting : t.sendQueue.running,
                        SendJobStatus.succeeded => t.sendQueue.succeeded,
                        SendJobStatus.failed => switch (job.result) {
                          SessionStatus.recipientBusy => t.sendPage.busy,
                          SessionStatus.declined => t.sendPage.rejected,
                          SessionStatus.connectionLost => t.transferActivity.retrying,
                          SessionStatus.sourceEnded => t.transferActivity.sourceEnded,
                          _ => t.sendQueue.failed,
                        },
                        SendJobStatus.canceled => t.sendQueue.canceled,
                      },
                      if (job.error != null)
                        job.error == const SelectedChannelUnavailable().toString()
                            ? labels.unavailable
                            : job.error == const SelectedLocalRouteUnavailable().toString()
                            ? labels.localRouteUnavailable
                            : job.error!,
                      if (sessions[job.id]?.errorMessage != null) sessions[job.id]!.errorMessage!,
                    ].join('\n'),
                  ),
                if (job.selectedChannel != null) Text('${labels.choose} · ${httpChannelLabel(job.selectedChannel!)}'),
                if (job.localRoute != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: StatusTag(label: '${labels.localExit} · ${localSendRouteLabel(job.localRoute!)}'),
                  ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  children: [
                    if (job.status == SendJobStatus.failed || job.status == SendJobStatus.canceled)
                      TextButton.icon(
                        key: ValueKey('send-retry-${job.id}'),
                        icon: Icon(job.restored ? Icons.play_arrow : Icons.refresh),
                        label: Text(job.restored ? (job.recoveryChecking ? recovery.checking : recovery.resume) : t.sendQueue.retry),
                        onPressed: job.recoveryChecking
                            ? null
                            : () {
                                try {
                                  queue.retry(job);
                                } catch (e) {
                                  context.showSnackBar(job.restored ? recovery.issue('unknown') : '${t.general.error}: $e');
                                }
                              },
                      ),
                    IconButton(
                      tooltip: job.terminal ? t.general.delete : t.general.cancel,
                      icon: Icon(job.terminal ? Icons.close : Icons.cancel_outlined),
                      onPressed: job.recoveryChecking
                          ? null
                          : () async {
                              try {
                                if (job.terminal) {
                                  await queue.removeAndWait(job.id);
                                } else {
                                  await queue.cancel(job.id);
                                }
                              } catch (_) {
                                if (context.mounted) context.showSnackBar(t.general.error);
                              }
                            },
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
