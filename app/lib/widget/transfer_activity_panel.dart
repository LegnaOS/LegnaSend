import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/util/send_recovery_strings.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_app/util/transfer_speed_label.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/util/web_transfer_activity_strings.dart';
import 'package:localsend_app/widget/accessible_icon_button.dart';
import 'package:localsend_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localsend_app/widget/receive_verification_tag.dart';
import 'package:localsend_app/widget/recovery_lifecycle_tag.dart';
import 'package:localsend_app/widget/send_queue_panel.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

String transferPhaseLabel(TransferPhase phase) => switch (phase) {
  TransferPhase.queued => t.sendQueue.queued,
  TransferPhase.preparing => t.transferActivity.preparing,
  TransferPhase.waiting => t.transferActivity.waiting,
  TransferPhase.transferring => t.transferActivity.transferring,
  TransferPhase.succeeded => t.transferActivity.succeeded,
  TransferPhase.failed => t.transferActivity.failed,
  TransferPhase.canceled => t.sendQueue.canceled,
  TransferPhase.unconfirmed => WebTransferActivityStrings(LocaleSettings.currentLocale).unconfirmed,
  TransferPhase.retrying => t.transferActivity.retrying,
  TransferPhase.sourceEnded => t.transferActivity.sourceEnded,
};

class TransferActivityPanel extends StatefulWidget {
  final TransferDirection initialDirection;
  final ValueNotifier<TransferDirection>? direction;
  final String? initialTaskKey;
  const TransferActivityPanel({required this.initialDirection, this.direction, this.initialTaskKey});
  @override
  State<TransferActivityPanel> createState() => _TransferActivityPanelState();
}

class _TransferActivityPanelState extends State<TransferActivityPanel> {
  late TransferDirection _direction = widget.initialDirection;
  final _selection = <TransferDirection, String>{};

  @override
  void initState() {
    super.initState();
    if (widget.initialTaskKey != null) _selection[_direction] = widget.initialTaskKey!;
    widget.direction?.addListener(_changeDirection);
  }

  void _changeDirection() {
    if (mounted) setState(() => _direction = widget.direction!.value);
  }

  @override
  void dispose() {
    widget.direction?.removeListener(_changeDirection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webLabels = WebTransferActivityStrings(Translations.of(context).$meta.locale);
    final tasks = context.watch(transferActivityProvider);
    final rates = context.watch(transferSpeedProvider);
    final selectedKey = _selection[_direction];
    final selected = tasks.where((t) => t.key == selectedKey).firstOrNull;
    final directional = tasks.where((t) => t.direction == _direction).toList();
    return PopScope(
      canPop: selectedKey == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selectedKey != null) setState(() => _selection.remove(_direction));
      },
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Short landscape windows and large accessibility text must scroll
              // controls with content rather than leave a zero-height task list.
              final compact = constraints.maxHeight < 400 || MediaQuery.textScalerOf(context).scale(14) > 21;
              Widget empty(String label) => compact
                  ? SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text(label)),
                      ),
                    )
                  : Center(child: Text(label));
              final controls = <Widget>[
                ListTile(
                  title: Text(t.transferActivity.title),
                  subtitle: Text(t.transferNavigation.keepRunning),
                  trailing: AccessibleIconButton(
                    label: t.transferNavigation.hide,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icons.expand_more,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final direction in TransferDirection.values)
                      ChoiceChip(
                        key: ValueKey('transfer-tab-${direction.name}'),
                        label: Text(
                          '${direction == TransferDirection.send ? t.transferActivity.send : t.transferActivity.receive} (${tasks.where((t) => t.direction == direction && t.active).length})',
                        ),
                        selected: _direction == direction,
                        onSelected: (_) {
                          setState(() => _direction = direction);
                          widget.direction?.value = direction;
                        },
                      ),
                  ],
                ),
                if (selectedKey != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _selection.remove(_direction)),
                      icon: const Icon(Icons.arrow_back),
                      label: Text(t.transferActivity.back),
                    ),
                  ),
              ];
              final content = selectedKey != null
                  ? selected == null
                        ? empty(t.transferActivity.ended)
                        : _TaskDetails(task: selected, sliver: compact)
                  : directional.isEmpty
                  ? empty(t.transferActivity.empty)
                  : _TaskList(
                      sliver: compact,
                      key: PageStorageKey('transfer-list-${_direction.name}'),
                      itemCount: directional.length,
                      itemBuilder: (context, index) {
                        final task = directional[index];
                        return ListTile(
                          key: ValueKey(task.key),
                          leading: Icon(task.direction == TransferDirection.send ? Icons.north : Icons.south),
                          title: Text(
                            task.peer.isEmpty && task.kind == TransferActivityKind.webResponse ? webLabels.sourceLabel(task) : task.peer,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (task.job?.restored == true)
                                SendRecoverySummary(job: task.job!)
                              else
                                Text(
                                  task.kind != TransferActivityKind.native
                                      ? '${webLabels.sourceLabel(task)} · ${webLabels.phaseFor(task, transferPhaseLabel(task.phase))}'
                                      : '${transferPhaseLabel(task.phase)} · ${task.files.length} · ${task.totalBytes.asReadableFileSize}',
                                ),
                              if (task.kind == TransferActivityKind.webResponse) _WebTaskTags(task: task),
                              if (task.verification != null) ReceiveVerificationTag(verification: task.verification!),
                              if (task.recovery != null) RecoveryLifecycleTag(recovery: task.recovery!),
                              if (task.phase == TransferPhase.transferring) ...[
                                Text(currentTransferSpeedLabel(rates[task.key])),
                                LinearProgressIndicator(
                                  value: task.totalKnown ? task.progress : (task.active ? null : (task.phase == TransferPhase.succeeded ? 1 : 0)),
                                ),
                              ],
                            ],
                          ),
                          trailing: task.needsAttention ? const Icon(Icons.error_outline) : const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _selection[_direction] = task.key),
                        );
                      },
                    );
              final footer = TextButton(
                onPressed: () => context.ref.notifier(acknowledgedTransferResultsProvider).acknowledge(tasks),
                child: Text(t.transferActivity.acknowledge),
              );
              if (compact) {
                return CustomScrollView(
                  key: PageStorageKey('compact-transfer-${selectedKey ?? _direction.name}'),
                  slivers: [
                    SliverToBoxAdapter(child: Column(children: controls)),
                    content,
                    SliverToBoxAdapter(child: footer),
                  ],
                );
              }
              return Column(
                children: [
                  ...controls,
                  Expanded(child: content),
                  footer,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TaskDetails extends StatelessWidget {
  final TransferActivity task;
  final bool sliver;
  const _TaskDetails({required this.task, required this.sliver});

  Future<void> _cancel(BuildContext context) async {
    final ref = context.ref;
    final nativeSend = task.kind == TransferActivityKind.native && task.direction == TransferDirection.send;
    final nativeReceive = task.kind == TransferActivityKind.native && task.direction == TransferDirection.receive;
    final webGeneration = task.kind == TransferActivityKind.webResponse ? ref.notifier(webTransferActivityProvider).generation : null;
    final sendAttempt = nativeSend && task.job == null ? ref.notifier(sendProvider).sessionAttemptIdentity(task.id) : null;
    final receiveGeneration = nativeReceive ? ref.notifier(serverProvider).listenerGeneration : null;
    final confirmed = await context.pushBottomSheet(() => const CancelSessionDialog());
    if (confirmed != true || !context.mounted) return;
    // Re-read after the dialog. A late button must not affect a replacement task.
    final current = ref.read(transferActivityProvider).where((t) => t.key == task.key).firstOrNull;
    if (current == null || !current.active) return;
    // Recovered jobs keep their task ID across attempts. A dialog belongs to
    // the attempt it displayed, not a later resume with the same visible key.
    if (nativeSend && task.job?.attemptRevision != current.job?.attemptRevision) return;
    if (nativeSend && task.job == null && !identical(sendAttempt, ref.notifier(sendProvider).sessionAttemptIdentity(task.id))) return;
    if (nativeReceive && receiveGeneration != ref.notifier(serverProvider).listenerGeneration) return;
    if (current.kind == TransferActivityKind.webApproval) {
      ref.notifier(serverProvider).declineWebDownloadRequest(current.id);
    } else if (current.kind == TransferActivityKind.webResponse) {
      final activities = ref.notifier(webTransferActivityProvider);
      if (activities.generation != webGeneration) return;
      final labels = WebTransferActivityStrings(Translations.of(context).$meta.locale);
      try {
        final canceled = await activities.cancel(current.id, expectedGeneration: webGeneration);
        if (!canceled && context.mounted) context.showSnackBar(labels.ended);
      } catch (_) {
        if (context.mounted) context.showSnackBar(labels.cancelFailed);
      }
    } else if (task.direction == TransferDirection.receive) {
      if (current.phase == TransferPhase.waiting) {
        ref.notifier(serverProvider).declineFileRequest(expectedSessionId: task.id);
      } else {
        ref.notifier(serverProvider).cancelSession(expectedSessionId: task.id);
      }
    } else if (current.job != null) {
      try {
        await ref.notifier(sendQueueProvider).cancel(task.id);
      } catch (_) {
        if (context.mounted) context.showSnackBar(SendRecoveryStrings(Translations.of(context).$meta.locale).issue('storage'));
      }
    } else {
      ref.notifier(sendProvider).cancelSession(task.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final webLabels = WebTransferActivityStrings(Translations.of(context).$meta.locale);
    final isWeb = task.kind != TransferActivityKind.native;
    final awaitingWeb = task.kind == TransferActivityKind.webApproval && task.phase == TransferPhase.waiting;
    final recovery = SendRecoveryStrings(Translations.of(context).$meta.locale);
    final routeLabels = SendRouteStrings(Translations.of(context).$meta.locale);
    final localRoute = task.direction == TransferDirection.send && !isWeb
        ? task.job?.localRoute ?? context.watch(sendProvider.select((sessions) => sessions[task.id]?.localRoute))
        : null;
    final rates = context.watch(transferSpeedProvider);
    final waitingReceive = !isWeb && task.direction == TransferDirection.receive && task.phase == TransferPhase.waiting;
    final selectedFiles = waitingReceive ? context.watch(selectedReceivingFilesProvider) : const <String, String>{};
    return _TaskList(
      sliver: sliver,
      key: PageStorageKey('transfer-detail-${task.key}'),
      padding: const EdgeInsets.all(16),
      itemCount: task.files.length + 1,
      itemBuilder: (context, index) {
        if (index > 0) {
          final file = task.files[index - 1];
          return ListTile(
            title: Text(file.name),
            subtitle: Text(task.totalKnown ? file.size.asReadableFileSize : webLabels.bytesFor(task, file.transferred.asReadableFileSize)),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.peer.isEmpty && task.kind == TransferActivityKind.webResponse ? webLabels.sourceLabel(task) : task.peer,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (task.job?.restored == true)
              SendRecoverySummary(job: task.job!)
            else
              Text(isWeb ? webLabels.phaseFor(task, transferPhaseLabel(task.phase)) : transferPhaseLabel(task.phase)),
            if (task.verification != null) ReceiveVerificationTag(verification: task.verification!),
            if (task.recovery != null) RecoveryLifecycleTag(recovery: task.recovery!),
            if (localRoute != null) StatusTag(label: '${routeLabels.localExit} · ${localSendRouteLabel(localRoute)}'),
            if (task.kind == TransferActivityKind.webResponse)
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _WebTaskTags(task: task),
                  AccessibleIconButton(
                    icon: Icons.info_outline,
                    label: webLabels.help,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(webLabels.help),
                        content: Text(webLabels.detailFor(task)),
                        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close))],
                      ),
                    ),
                  ),
                ],
              ),
            if (task.phase == TransferPhase.transferring || !task.active) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: task.totalKnown ? task.progress : (task.active ? null : (task.phase == TransferPhase.succeeded ? 1 : 0)),
                color: task.needsAttention ? Theme.of(context).colorScheme.error : null,
                semanticsLabel: task.phase == TransferPhase.unconfirmed ? webLabels.unconfirmed : null,
              ),
              Text(
                task.totalKnown
                    ? '${task.transferredBytes.asReadableFileSize} / ${task.totalBytes.asReadableFileSize}'
                    : webLabels.bytesFor(task, task.transferredBytes.asReadableFileSize),
              ),
              if (task.phase == TransferPhase.transferring) Text(currentTransferSpeedLabel(rates[task.key])),
            ],
            if (task.error != null && task.job?.restored != true)
              SelectableText(task.error == const SelectedLocalRouteUnavailable().toString() ? routeLabels.localRouteUnavailable : task.error!),
            Wrap(
              spacing: 8,
              children: [
                if (awaitingWeb) ...[
                  FilledButton(
                    onPressed: () => ref.notifier(serverProvider).acceptWebDownloadRequest(task.id),
                    child: Text(t.transferActivity.accept),
                  ),
                  TextButton(
                    onPressed: () => ref.notifier(serverProvider).declineWebDownloadRequest(task.id),
                    child: Text(t.transferActivity.decline),
                  ),
                ] else if (waitingReceive) ...[
                  FilledButton(
                    onPressed: selectedFiles.isEmpty
                        ? null
                        : () async {
                            final session = ref.read(serverProvider)?.session;
                            if (session?.sessionId != task.id || session?.status != SessionStatus.waiting) return;
                            await ref
                                .notifier(serverProvider)
                                .acceptFileRequest(Map.of(ref.read(selectedReceivingFilesProvider)), expectedSessionId: task.id);
                          },
                    child: Text(t.transferActivity.accept),
                  ),
                  TextButton(
                    onPressed: () => ref.notifier(serverProvider).declineFileRequest(expectedSessionId: task.id),
                    child: Text(t.transferActivity.decline),
                  ),
                ] else if (task.active)
                  TextButton(onPressed: () => _cancel(context), child: Text(t.general.cancel)),
                if (task.job != null && (task.job!.status == SendJobStatus.failed || task.job!.status == SendJobStatus.canceled))
                  TextButton(
                    onPressed: task.job!.recoveryChecking || task.recovery?.failure?.kind == UploadRecoveryFailureKind.sourceChanged
                        ? null
                        : () {
                            final current = ref.read(sendQueueProvider).where((j) => j.id == task.id).firstOrNull;
                            if (current == null || !current.terminal) return;
                            try {
                              ref.notifier(sendQueueProvider).retry(current);
                            } catch (e) {
                              context.showSnackBar(current.restored ? recovery.issue('unknown') : '${t.general.error}: $e');
                            }
                          },
                    child: Text(task.job!.restored ? (task.job!.recoveryChecking ? recovery.checking : recovery.resume) : t.sendQueue.retry),
                  ),
              ],
            ),
            const Divider(),
            Text(t.transferActivity.files, style: Theme.of(context).textTheme.titleMedium),
          ],
        );
      },
    );
  }
}

class _WebTaskTags extends StatelessWidget {
  final TransferActivity task;
  const _WebTaskTags({required this.task});
  @override
  Widget build(BuildContext context) {
    final labels = WebTransferActivityStrings(Translations.of(context).$meta.locale);
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        if (task.workspaceName != null)
          StatusTag(
            tooltip: task.workspaceName,
            child: Text(task.workspaceName!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        StatusTag(label: labels.operationLabel(task)),
        if (task.origin == 'api') const StatusTag(label: 'API'),
      ],
    );
  }
}

/// Retains lazy construction for large file manifests in both layout modes.
class _TaskList extends StatelessWidget {
  final bool sliver;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry? padding;

  const _TaskList({super.key, required this.sliver, required this.itemCount, required this.itemBuilder, this.padding});

  @override
  Widget build(BuildContext context) {
    if (sliver) {
      return SliverPadding(
        padding: padding ?? EdgeInsets.zero,
        sliver: SliverList(delegate: SliverChildBuilderDelegate(itemBuilder, childCount: itemCount)),
      );
    }
    return ListView.builder(key: key, padding: padding, itemCount: itemCount, itemBuilder: itemBuilder);
  }
}
