import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/api/api_source_strings.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/util/workspace/approved_workspace_source.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

class WorkspaceSourcesPage extends StatefulWidget {
  final Future<String?> Function()? pickDirectory;
  const WorkspaceSourcesPage({super.key, this.pickDirectory});
  @override
  State<WorkspaceSourcesPage> createState() => _WorkspaceSourcesPageState();
}

class _WorkspaceSourcesPageState extends State<WorkspaceSourcesPage> {
  bool _busy = false;
  ApiSourceStrings get _text => ApiSourceStrings(TranslationProvider.of(context).locale.languageTag);
  Future<void> _approve() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await (widget.pickDirectory ?? pickDirectoryPath)();
      if (path == null || !mounted) return;
      final controller = TextEditingController(text: path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? 'Directory');
      final text = _text;
      final approved = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(text.approve),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text.approveHint),
                const SizedBox(height: 12),
                SelectableText(path),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('approved-source-name'),
                  controller: controller,
                  maxLength: 120,
                  decoration: InputDecoration(labelText: text.name),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(text.cancel)),
            FilledButton(
              key: const ValueKey('approved-source-confirm'),
              onPressed: () {
                if (controller.text.trim().isNotEmpty) Navigator.pop(context, controller.text.trim());
              },
              child: Text(text.confirm),
            ),
          ],
        ),
      );
      // Dialog animation may still refer to its controller; let the route dispose first.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      controller.dispose();
      if (approved == null || !mounted) return;
      await context.ref
          .notifier(workspaceCatalogProvider)
          .catalog
          .approveSource(
            name: approved,
            source: WorkspaceSource(
              kind: path.startsWith('content://') ? WorkspaceSourceKind.androidTree : WorkspaceSourceKind.directory,
              locator: path,
            ),
          );
    } catch (_) {
      if (mounted) context.showSnackBar(_text.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ApprovedWorkspaceSource source) async {
    final text = _text;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.revoke),
        content: Text(text.revokeHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(text.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(text.confirm)),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.ref.notifier(workspaceCatalogProvider).catalog.revokeSource(source.id);
    } catch (_) {
      if (mounted) context.showSnackBar(text.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text, catalog = context.ref.watch(workspaceCatalogProvider);
    return Scaffold(
      appBar: AppBar(title: Text(text.sources)),
      body: ResponsiveListView(
        maxWidth: 840,
        padding: const EdgeInsets.all(20),
        children: [
          Text(text.hint),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('approve-workspace-source'),
              onPressed: _busy || !catalog.initialized ? null : _approve,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(text.approve),
            ),
          ),
          const SizedBox(height: 16),
          for (final source in catalog.approvedSources)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(source.name, style: Theme.of(context).textTheme.titleMedium)),
                        IconButton(
                          tooltip: text.copy,
                          onPressed: () => Clipboard.setData(ClipboardData(text: source.id)),
                          icon: const Icon(Icons.copy, size: 18),
                        ),
                        IconButton(tooltip: text.revoke, onPressed: _busy ? null : () => _revoke(source), icon: const Icon(Icons.link_off)),
                      ],
                    ),
                    SelectableText(source.id),
                    const SizedBox(height: 6),
                    SelectableText(source.source.locator, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
