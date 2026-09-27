import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/workspace_password_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

class WorkspacePasswordResult {
  final String? verifier;
  const WorkspacePasswordResult(this.verifier);
}

class WorkspacePasswordDialog extends StatefulWidget {
  final String? verifier;
  const WorkspacePasswordDialog({super.key, this.verifier});
  @override
  State<WorkspacePasswordDialog> createState() => _WorkspacePasswordDialogState();
}

class _WorkspacePasswordDialogState extends State<WorkspacePasswordDialog> {
  late bool _protected = widget.verifier != null;
  final _password = TextEditingController(), _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _password.clear();
    _confirm.clear();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_protected) {
      Navigator.pop(context, const WorkspacePasswordResult(null));
      return;
    }
    if (_password.text.isEmpty && widget.verifier != null) {
      Navigator.pop(context, WorkspacePasswordResult(widget.verifier));
      return;
    }
    if (_password.text.runes.length < 4 || _password.text.runes.length > 128 || _password.text != _confirm.text) {
      setState(() => _error = 'invalid');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verifier = await context.ref.read(workspacePasswordProvider)(_password.text);
      if (!mounted) return;
      _password.clear();
      _confirm.clear();
      Navigator.pop(context, WorkspacePasswordResult(verifier));
    } catch (_) {
      if (mounted) setState(() => _error = 'failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Translations.of(context).directoryWorkspaces;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(text.access),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(text.protected),
                  value: _protected,
                  onChanged: _busy ? null : (value) => setState(() => _protected = value),
                ),
                Text(text.passwordHint),
                if (_protected) ...[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(labelText: text.password, helperText: widget.verifier != null ? text.keepPassword : null),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(labelText: text.confirmPassword),
                    onSubmitted: (_) => _save(),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error == 'invalid' ? text.passwordInvalid : text.failed,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.general.cancel)),
          FilledButton(onPressed: _busy ? null : _save, child: Text(t.general.save)),
        ],
      ),
    );
  }
}
