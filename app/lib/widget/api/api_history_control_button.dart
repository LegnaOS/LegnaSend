import 'package:flutter/material.dart';
import 'package:localsend_app/util/api/api_history_control.dart';

/// call executes the real API console with a captured listener and credential.
/// Returns the decoded successful body, and throws on non-200/invalid responses.
class ApiHistoryControlButton extends StatefulWidget {
  final String language;
  final bool enabled;
  final Future<Map<String, dynamic>> Function(String operation, Map<String, Object>? body) call;
  final ValueChanged<bool> onBusy;
  final ValueChanged<Map<String, dynamic>>? onRefreshed;
  const ApiHistoryControlButton({
    super.key,
    required this.language,
    required this.enabled,
    required this.call,
    required this.onBusy,
    this.onRefreshed,
  });
  @override
  State<ApiHistoryControlButton> createState() => _ApiHistoryControlButtonState();
}

class _ApiHistoryControlButtonState extends State<ApiHistoryControlButton> {
  bool _busy = false;
  bool _dialogVisible = false;
  Future<void> run() async {
    if (_busy || !widget.enabled) return;
    final text = ApiHistoryControlStrings(widget.language);
    final call = widget.call;
    setState(() => _busy = true);
    widget.onBusy(true);
    try {
      final before = await call('listRequests', null);
      final target = ApiHistoryClearTarget.fromPage(before);
      if (!mounted) return;
      setState(() => _dialogVisible = true);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-history-clear-confirm'),
          title: Text(text.title),
          content: Text(text.explanation),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(text.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(text.confirm)),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _dialogVisible = false);
      if (accepted != true) return;
      final result = await call('clearRequests', target.body);
      final count = target.validateResult(result);
      if (!mounted) return;
      // A successful mutation remains successful even if the subsequent read
      // fails. Do not retry the mutation automatically under a newer generation.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text.result(count))));
      try {
        final refreshed = await call('listRequests', null);
        if (mounted) widget.onRefreshed?.call(refreshed);
      } catch (_) {}
    } catch (_) {
      if (mounted) {
        setState(() => _dialogVisible = true);
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            key: const ValueKey('api-history-clear-failed'),
            title: Text(text.title),
            content: Text(text.failed),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(text.close))],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _dialogVisible = false;
        });
        widget.onBusy(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('api-history-clear'),
    onPressed: widget.enabled && !_busy ? run : null,
    tooltip: ApiHistoryControlStrings(widget.language).title,
    icon: _busy && !_dialogVisible
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.delete_sweep_outlined),
  );
}
