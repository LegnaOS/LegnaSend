import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/directory_upload_approval_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/util/directory_upload_approval_strings.dart';
import 'package:localsend_app/util/transfer_speed_label.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/transfer_wake_lock.dart';
import 'package:localsend_app/widget/transfer_wake_lock_scope.dart';
import 'package:localsend_app/widget/directory_upload_approval_panel.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// A global, safe-area-aware entry above the Navigator. Its reserved strip keeps
/// badges away from page actions, modal content and device drag targets.
class TransferActivityShell extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const TransferActivityShell({required this.child, required this.navigatorKey});

  @override
  State<TransferActivityShell> createState() => _TransferActivityShellState();
}

class _TransferActivityShellState extends State<TransferActivityShell> {
  bool _panelOpen = false;
  ModalRoute<void>? _panelRoute;
  int _panelGeneration = 0;
  bool _webPageOpen = false;
  ModalRoute<void>? _approvalRoute;
  int _approvalGeneration = 0;
  final _direction = ValueNotifier(TransferDirection.send);
  final _toolbarFocus = FocusScopeNode(debugLabel: 'Transfer toolbar');
  final _contentFocus = FocusScopeNode(debugLabel: 'Application content');

  KeyEventResult _switchRegion(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f6 || _toolbarFocus.context == null) return KeyEventResult.ignored;
    if (_toolbarFocus.hasFocus) {
      _contentFocus.requestFocus();
    } else {
      final restore = _toolbarFocus.focusedChild;
      _toolbarFocus.requestFocus();
      if (restore == null) _toolbarFocus.nextFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _toolbarFocus.dispose();
    _contentFocus.dispose();
    _direction.dispose();
    super.dispose();
  }

  Future<void> _openApprovals() async {
    final context = widget.navigatorKey.currentState?.overlay?.context;
    if (context == null) return;
    final previous = _approvalRoute;
    if (previous != null) {
      if (previous.isCurrent) return;
      previous.navigator?.removeRoute(previous);
    }
    final generation = ++_approvalGeneration;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) {
          _approvalRoute = ModalRoute.of<void>(context);
          return const DirectoryUploadApprovalPanel();
        },
      );
    } finally {
      if (generation == _approvalGeneration) _approvalRoute = null;
    }
  }

  Future<void> _openWeb() async {
    final navigator = widget.navigatorKey.currentState;
    if (_webPageOpen || navigator == null) return;
    setState(() => _webPageOpen = true);
    try {
      await navigator.push(MaterialPageRoute<void>(builder: (_) => const WebSharePage(resume: true)));
    } finally {
      if (mounted) setState(() => _webPageOpen = false);
    }
  }

  Future<void> _open(TransferDirection direction) async {
    final context = widget.navigatorKey.currentState?.overlay?.context;
    _direction.value = direction;
    if (context == null) return;
    if (_panelOpen) {
      final previous = _panelRoute;
      if (previous == null || previous.isCurrent) return;
      // A receive prompt may cover the sheet. Replace only our owned sheet;
      // never pop the prompt or any unrelated route to bring tasks forward.
      previous.navigator?.removeRoute(previous);
    }
    final generation = ++_panelGeneration;
    setState(() => _panelOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) {
          _panelRoute = ModalRoute.of<void>(context);
          return TransferActivityPanel(initialDirection: direction, direction: _direction);
        },
      );
    } finally {
      if (mounted && generation == _panelGeneration) {
        setState(() {
          _panelOpen = false;
          _panelRoute = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = context.watch(transferActivityProvider);
    final approvals = context.watch(directoryUploadApprovalProvider);
    final approvalLabels = DirectoryUploadApprovalStrings(Translations.of(context).$meta.locale);
    final network = context.watch(networkEnvironmentProvider);
    final webActive = context.watch(serverProvider.select((server) => server?.web != null));
    final acknowledged = context.watch(acknowledgedTransferResultsProvider);
    final visible = tasks.where((task) => task.active || !acknowledged.contains(task.resultKey)).toList();
    final body = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _switchRegion,
      child: Column(
        children: [
          if (visible.isNotEmpty || webActive || network.hasNetworkOverlay || approvals.isNotEmpty)
            FocusScope(
              node: _toolbarFocus,
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                child: Material(
                  child: SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 6,
                          children: [
                            if (network.hasNetworkOverlay) NetworkEnvironmentBadge(network: network, navigatorKey: widget.navigatorKey),
                            if (approvals.isNotEmpty)
                              StatusTag(
                                key: const ValueKey('workspace-upload-approval-badge'),
                                onTap: _openApprovals,
                                icon: Icons.mark_email_unread_outlined,
                                label: approvalLabels.badge(approvals.where((request) => request.pending).length),
                              ),
                            if (webActive)
                              StatusTag(
                                key: const ValueKey('web-sharing-badge'),
                                onTap: _openWeb,
                                icon: Icons.link,
                                label: t.transferNavigation.sharing,
                              ),
                            for (final direction in TransferDirection.values)
                              if (visible.any((t) => t.direction == direction))
                                _DirectionBadge(
                                  direction: direction,
                                  tasks: visible.where((t) => t.direction == direction).toList(),
                                  onTap: () => _open(direction),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            // Navigator routes contain BlockSemantics. Bound them to their own
            // container so they cannot hide the earlier global toolbar nodes.
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: FocusScope(node: _contentFocus, child: widget.child),
            ),
          ),
        ],
      ),
    );
    return TransferWakeLockScope(
      manager: context.read(transferWakeLockProvider),
      active:
          checkPlatform([TargetPlatform.iOS]) &&
          tasks.any((task) => task.phase == TransferPhase.preparing || task.phase == TransferPhase.transferring),
      child: body,
    );
  }
}

class _DirectionBadge extends StatelessWidget {
  final TransferDirection direction;
  final List<TransferActivity> tasks;
  final VoidCallback? onTap;
  const _DirectionBadge({required this.direction, required this.tasks, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = direction == TransferDirection.send ? t.transferActivity.send : t.transferActivity.receive;
    final active = tasks.where((t) => t.active).length;
    final attention = tasks.any((t) => t.needsAttention);
    final progress = activeTransferProgress(tasks, direction);
    final rates = context.watch(transferSpeedProvider);
    final speed = directionalTransferSpeed(rates, tasks, direction);
    final transferring = tasks.any((task) => task.phase == TransferPhase.transferring);
    return StatusTag(
      semanticsLabel: '$label $active · ${t.transferActivity.title} · ${tasks.map((task) => transferPhaseLabel(task.phase)).toSet().join(', ')}',
      key: ValueKey('transfer-badge-${direction.name}'),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(direction == TransferDirection.send ? Icons.north : Icons.south, size: 16),
          const SizedBox(width: 4),
          Text('$label $active'),
          if (transferring) ...[
            const SizedBox(width: 6),
            Text(transferSpeedValue(speed), key: ValueKey('transfer-speed-${direction.name}'), style: const TextStyle(fontSize: 11)),
          ],
          if (progress != null) ...[
            const SizedBox(width: 6),
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(value: progress, strokeWidth: 2)),
          ],
          if (progress == null && active > 0) ...[
            const SizedBox(width: 4),
            const Icon(Icons.hourglass_top, size: 16),
          ],
          if (attention) ...[
            const SizedBox(width: 4),
            const Icon(Icons.error_outline, size: 16),
          ] else if (active == 0) ...[
            const SizedBox(width: 4),
            Icon(tasks.any((task) => task.phase == TransferPhase.canceled) ? Icons.cancel_outlined : Icons.task_alt, size: 16),
          ],
        ],
      ),
    );
  }
}
