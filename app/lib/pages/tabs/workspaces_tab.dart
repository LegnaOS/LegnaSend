import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/pages/workspace_sources_page.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/api/api_source_strings.dart';
import 'package:localsend_app/util/native/ios_workspace_grants.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/util/workspace/workspace_batch_strings.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:localsend_app/util/workspace/workspace_draft_defaults.dart';
import 'package:localsend_app/widget/dialogs/workspace_password_dialog.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:refena_flutter/refena_flutter.dart';

class WorkspacesTab extends StatefulWidget {
  const WorkspacesTab({super.key});
  @override
  State<WorkspacesTab> createState() => _WorkspacesTabState();
}

class _WorkspacesTabState extends State<WorkspacesTab> {
  bool _busy = false;
  bool _selecting = false;
  final _selected = <String>{};

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return;
      await context.ref.notifier(directoryPublicationProvider).synchronize();
    } catch (_) {
      if (mounted) context.showSnackBar(t.directoryWorkspaces.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([DirectoryWorkspace? entry]) async {
    final slug = nextWorkspaceSlug(context.ref.read(workspaceCatalogProvider).entries.map((entry) => entry.slug));
    final result = await showDialog<_WorkspaceDraft>(
      context: context,
      builder: (_) => _WorkspaceEditor(entry: entry, initialName: '${t.directoryWorkspaces.title} ${slug.substring(9)}', initialSlug: slug),
    );
    if (result == null) return;
    if (!mounted) {
      if (result.newGrant != null) {
        try {
          await result.grants.discard(result.newGrant!);
        } catch (_) {}
      }
      return;
    }
    var saved = false;
    await _run(() async {
      final catalog = context.ref.notifier(workspaceCatalogProvider).catalog;
      if (entry == null) {
        await catalog.create(name: result.name, slug: result.slug, source: result.source, visible: result.visible);
      } else {
        await catalog.update(entry.id, name: result.name, slug: result.slug, source: result.source, visible: result.visible);
      }
      saved = true;
      if (result.newGrant != null) await result.grants.adopt(result.newGrant!);
    });
    if (!saved && result.newGrant != null) {
      try {
        await result.grants.discard(result.newGrant!);
      } catch (_) {
        /* Keep a failed cleanup private; never delete the external source. */
      }
    }
  }

  Future<void> _startServiceIfNeeded() async {
    final ref = context.ref;
    if (ref.read(serverProvider) != null) return;
    await ref.notifier(serverProvider).startServerFromSettings();
    if (ref.read(serverProvider) == null) throw StateError('Workspace listener did not start');
  }

  Future<void> _enable(DirectoryWorkspace entry) => _run(() async {
    final enabled = await context.ref.notifier(workspaceCatalogProvider).catalog.enable(entry.id);
    if (enabled.enabled) await _startServiceIfNeeded();
  });

  Future<void> _protection(DirectoryWorkspace entry) async {
    final result = await showDialog<WorkspacePasswordResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WorkspacePasswordDialog(verifier: entry.passwordHash),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await context.ref.notifier(workspaceCatalogProvider).catalog.setPassword(entry.id, result.verifier);
    });
  }

  Future<void> _uploadPermission(DirectoryWorkspace entry) async {
    var enabled = entry.allowUpload;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final text = Translations.of(context).directoryWorkspaces;
          return AlertDialog(
            title: Text(text.uploadPermission),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile.adaptive(
                    key: const ValueKey('workspace-upload-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(text.allowUpload),
                    value: enabled,
                    onChanged: (value) => update(() => enabled = value),
                  ),
                  Text(text.uploadHint),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
              FilledButton(onPressed: () => Navigator.pop(context, enabled), child: Text(t.general.save)),
            ],
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await context.ref.notifier(workspaceCatalogProvider).catalog.setAllowUpload(entry.id, result);
    });
  }

  Future<void> _confirm(DirectoryWorkspace entry, bool destroy) async {
    final text = t.directoryWorkspaces;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(destroy ? text.destroy : text.close),
        content: Text(text.stopHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.general.confirm)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      final catalog = context.ref.notifier(workspaceCatalogProvider).catalog;
      if (destroy) {
        await catalog.destroy(entry.id);
      } else {
        await catalog.disable(entry.id);
      }
    });
  }

  Future<void> _batch(bool enabled) async {
    if (_busy) return;
    final ref = context.ref;
    final entries = ref.read(workspaceCatalogProvider).entries.where((entry) => _selected.contains(entry.id)).toList(growable: false);
    if (entries.isEmpty) return;
    final labels = WorkspaceBatchStrings(TranslationProvider.of(context).locale.languageTag);
    final text = t.directoryWorkspaces;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(enabled ? labels.open : labels.close),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(labels.hint),
                const SizedBox(height: 12),
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${entry.name} · /${entry.slug}/\n${entry.visible ? text.visible : text.hidden} · ${entry.passwordHash == null ? text.openAccess : text.protected} · ${entry.allowUpload ? text.allowUpload : text.readOnly}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.general.confirm)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    List<WorkspaceBatchResult>? results;
    try {
      results = await ref.notifier(workspaceCatalogProvider).catalog.setEnabledBatch(entries, enabled);
      if (enabled && ref.read(workspaceCatalogProvider).publishable.isNotEmpty) await _startServiceIfNeeded();
      await ref.notifier(directoryPublicationProvider).synchronize();
    } catch (_) {
      if (mounted && results == null) context.showSnackBar(text.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || results == null) return;
    final publication = ref.read(directoryPublicationProvider);
    final current = ref.read(workspaceCatalogProvider);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(labels.results),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final result in results!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      '${result.name}: ${switch (result.outcome) {
                        WorkspaceBatchOutcome.invalid => labels.invalid,
                        WorkspaceBatchOutcome.changed => labels.changed,
                        WorkspaceBatchOutcome.failed => labels.failed,
                        WorkspaceBatchOutcome.applied => (enabled ? current.entries.any((entry) => entry.id == result.id && publication.published[result.id] == entry.generation) : !publication.published.containsKey(result.id)) ? labels.applied : labels.pending,
                      }}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.close))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final text = t.directoryWorkspaces;
    final batch = WorkspaceBatchStrings(TranslationProvider.of(context).locale.languageTag);
    final ref = context.ref;
    final catalog = ref.watch(workspaceCatalogProvider);
    final publication = ref.watch(directoryPublicationProvider);
    final server = ref.watch(serverProvider);
    final network = ref.watch(localIpProvider);
    final pending = _busy || publication.busy || catalog.checking;
    return ResponsiveListView(
      maxWidth: 840,
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text(text.title, style: Theme.of(context).textTheme.headlineSmall)),
            FilledButton.icon(
              onPressed: pending || !catalog.initialized ? null : _edit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.general.add),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              key: const ValueKey('workspace-batch-select'),
              onPressed: pending
                  ? null
                  : () => setState(() {
                      _selecting = !_selecting;
                      if (!_selecting) _selected.clear();
                    }),
              icon: const Icon(Icons.checklist),
              label: Text(batch.select),
            ),
            if (_selecting) ...[
              TextButton(
                key: const ValueKey('workspace-batch-open'),
                onPressed: pending || _selected.isEmpty ? null : () => _batch(true),
                child: Text('${batch.open} (${_selected.length})'),
              ),
              TextButton(
                key: const ValueKey('workspace-batch-close'),
                onPressed: pending || _selected.isEmpty ? null : () => _batch(false),
                child: Text(batch.close),
              ),
              TextButton(onPressed: pending ? null : () => setState(_selected.clear), child: Text(batch.clear)),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('workspace-approved-sources'),
            onPressed: pending || !catalog.initialized
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkspaceSourcesPage())),
            icon: const Icon(Icons.folder_shared_outlined, size: 18),
            label: Text(ApiSourceStrings(TranslationProvider.of(context).locale.languageTag).sources),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            StatusTag(label: server == null ? text.serverOff : '${server.https ? 'HTTPS · TLS' : 'HTTP'} · ${server.port}'),
            if (pending) StatusTag(label: text.syncing, icon: Icons.sync),
            if (server == null)
              StatusTag(
                key: const ValueKey('workspace-start-service'),
                label: text.startService,
                icon: Icons.play_arrow,
                onTap: pending ? null : () => _run(_startServiceIfNeeded),
              ),
          ],
        ),
        if (publication.failed || catalog.failure != null) ...[
          const SizedBox(height: 12),
          Text(text.syncFailed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: pending
                  ? null
                  : () => _run(() async {
                      if (!catalog.initialized) await ref.notifier(workspaceCatalogProvider).catalog.reload();
                    }),
              icon: const Icon(Icons.refresh),
              label: Text(text.retry),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (catalog.initialized && catalog.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text.empty, textAlign: TextAlign.center),
          ),
        for (final entry in catalog.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_selecting)
                          Checkbox(
                            key: ValueKey('workspace-select-${entry.id}'),
                            value: _selected.contains(entry.id),
                            semanticLabel: '${batch.select}: ${entry.name}',
                            onChanged: pending
                                ? null
                                : (selected) => setState(() {
                                    if (selected == true) {
                                      _selected.add(entry.id);
                                    } else {
                                      _selected.remove(entry.id);
                                    }
                                  }),
                          )
                        else
                          const Icon(Icons.folder_outlined, size: 23),
                        const SizedBox(width: 10),
                        Expanded(child: Text(entry.name, style: Theme.of(context).textTheme.titleMedium)),
                        IconButton(
                          tooltip: t.general.edit,
                          onPressed: pending ? null : () => _edit(entry),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          tooltip: text.destroy,
                          onPressed: pending ? null : () => _confirm(entry, true),
                          icon: const Icon(Icons.delete_outline, size: 20),
                        ),
                      ],
                    ),
                    SelectableText(entry.source.locator, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        StatusTag(
                          label: publication.published[entry.id] == entry.generation && entry.enabled
                              ? text.serving
                              : publication.published.containsKey(entry.id)
                              ? text.previousServing
                              : entry.invalidReason != null
                              ? text.invalid
                              : text.closed,
                        ),
                        StatusTag(
                          label: entry.visible ? text.visible : text.hidden,
                          icon: entry.visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        ),
                        StatusTag(label: '/${entry.slug}/'),
                        StatusTag(
                          label: (entry.enabled || publication.published.containsKey(entry.id)) && publication.published[entry.id] != entry.generation
                              ? text.uploadPending
                              : entry.allowUpload
                              ? text.allowUpload
                              : text.readOnly,
                          icon: entry.allowUpload ? Icons.upload_file_outlined : Icons.folder_outlined,
                        ),
                        StatusTag(
                          label: (entry.enabled || publication.published.containsKey(entry.id)) && publication.published[entry.id] != entry.generation
                              ? text.accessPending
                              : entry.passwordHash == null
                              ? text.openAccess
                              : text.protected,
                          icon: entry.passwordHash == null ? Icons.lock_open : Icons.lock_outline,
                        ),
                        if (entry.invalidReason != null) StatusTag(label: text.reasons[entry.invalidReason!.name] ?? text.failed),
                      ],
                    ),
                    if (server != null && publication.published[entry.id] == entry.generation && entry.enabled) ...[
                      const SizedBox(height: 10),
                      for (final address in network.addresses.where((address) => !address.isIpv6 || !address.address.startsWith('fe80:')))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              StatusTag(label: address.label, icon: address.isTunnel ? Icons.shield_outlined : Icons.lan_outlined),
                              if (address.cidr != null) StatusTag(label: address.cidr!),
                              SizedBox(
                                width: double.infinity,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: SelectableText(
                                        Uri(
                                          scheme: server.https ? 'https' : 'http',
                                          host: address.address,
                                          port: server.port,
                                          path: '/${entry.slug}/',
                                        ).toString(),
                                        style: Theme.of(context).textTheme.bodyMedium,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton.icon(
                                      key: ValueKey('workspace-copy-${entry.id}-${address.address}'),
                                      onPressed: () async {
                                        final link = Uri(
                                          scheme: server.https ? 'https' : 'http',
                                          host: address.address,
                                          port: server.port,
                                          path: '/${entry.slug}/',
                                        );
                                        await Clipboard.setData(ClipboardData(text: link.toString()));
                                        if (context.mounted) context.showSnackBar(t.general.copiedToClipboard);
                                      },
                                      icon: const Icon(Icons.copy_outlined, size: 18),
                                      label: Text(t.general.copy),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: pending ? null : () => _uploadPermission(entry),
                          icon: const Icon(Icons.upload_file_outlined, size: 18),
                          label: Text(text.uploadPermission),
                        ),
                        TextButton.icon(
                          onPressed: pending ? null : () => entry.enabled ? _confirm(entry, false) : _enable(entry),
                          icon: Icon(entry.enabled ? Icons.stop_circle_outlined : Icons.play_arrow, size: 18),
                          label: Text(entry.enabled ? text.close : text.enable),
                        ),
                        TextButton.icon(
                          onPressed: pending ? null : () => _protection(entry),
                          icon: const Icon(Icons.lock_outline, size: 18),
                          label: Text(text.access),
                        ),
                        TextButton(
                          onPressed: pending
                              ? null
                              : () => _run(() async {
                                  await ref.notifier(workspaceCatalogProvider).catalog.validate(entry.id);
                                }),
                          child: Text(text.validate),
                        ),
                        TextButton(
                          onPressed: pending
                              ? null
                              : () => _run(() async {
                                  await ref.notifier(workspaceCatalogProvider).catalog.update(entry.id, visible: !entry.visible);
                                }),
                          child: Text(entry.visible ? text.hide : text.show),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspaceDraft {
  final String name, slug;
  final WorkspaceSource source;
  final bool visible;
  final String? newGrant;
  final IosWorkspaceGrants grants;
  _WorkspaceDraft(this.name, this.slug, this.source, this.visible, {this.newGrant, this.grants = const IosWorkspaceGrants()});
}

class _WorkspaceEditor extends StatefulWidget {
  final DirectoryWorkspace? entry;
  final String initialName, initialSlug;
  const _WorkspaceEditor({this.entry, required this.initialName, required this.initialSlug});
  @override
  State<_WorkspaceEditor> createState() => _WorkspaceEditorState();
}

class _WorkspaceEditorState extends State<_WorkspaceEditor> {
  late final _name = TextEditingController(text: widget.entry?.name ?? widget.initialName);
  late final _slug = TextEditingController(text: widget.entry?.slug ?? widget.initialSlug);
  late final _root = TextEditingController(text: widget.entry?.source.locator);
  late bool _visible = widget.entry?.visible ?? true;
  String? _error;
  WorkspaceSource? _picked;
  IosWorkspaceGrants? _grants;
  bool _picking = false, _accepted = false, _nameEdited = false;

  void _setPickedPath(String path) {
    _root.text = path;
    if (widget.entry == null && !_nameEdited) {
      final name = workspaceFolderName(path);
      if (name.isNotEmpty) _name.text = name;
    }
  }

  InputDecoration _field(String label) => InputDecoration(
    labelText: label,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
  );
  @override
  void dispose() {
    if (!_accepted && _picked?.grantId != null) {
      unawaited(_grants!.discard(_picked!.grantId!).catchError((Object _) {}));
    }
    _name.dispose();
    _slug.dispose();
    _root.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Translations.of(context).directoryWorkspaces;
    return AlertDialog(
      title: Text(widget.entry == null ? text.create : t.general.edit),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('workspace-name'),
                controller: _name,
                onChanged: (_) => _nameEdited = true,
                decoration: _field(text.name),
                maxLength: 120,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _slug,
                enabled: widget.entry?.enabled != true,
                key: const ValueKey('workspace-custom-path'),
                autocorrect: false,
                enableSuggestions: false,
                decoration: _field(text.slug).copyWith(prefixText: '/', suffixText: '/'),
                maxLength: 48,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _root,
                enabled: widget.entry?.enabled != true,
                readOnly: context.ref.read(iosWorkspaceGrantsProvider).supported,
                onChanged: (_) {
                  if (widget.entry == null && !_nameEdited) {
                    final name = workspaceFolderName(_root.text);
                    if (name.isNotEmpty) _name.text = name;
                  }
                },
                decoration: _field(text.root).copyWith(
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: text.choose,
                    onPressed: widget.entry?.enabled == true || _picking
                        ? null
                        : () async {
                            setState(() => _picking = true);
                            final grants = context.ref.read(iosWorkspaceGrantsProvider);
                            _grants = grants;
                            try {
                              if (grants.supported) {
                                final source = await grants.pick();
                                if (source != null) {
                                  if (!mounted) {
                                    await grants.discard(source.grantId!);
                                    return;
                                  }
                                  final previous = _picked?.grantId;
                                  setState(() {
                                    _picked = source;
                                    _setPickedPath(source.locator);
                                  });
                                  if (previous != null) await grants.discard(previous);
                                }
                              } else {
                                final path = await pickDirectoryPath();
                                if (mounted && path != null) setState(() => _setPickedPath(path));
                              }
                            } catch (_) {
                              if (mounted) setState(() => _error = text.failed);
                            } finally {
                              if (mounted) setState(() => _picking = false);
                            }
                          },
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(text.visible),
                value: _visible,
                onChanged: (value) => setState(() => _visible = value),
              ),
              if (!_visible) Text(text.hiddenHint, style: Theme.of(context).textTheme.bodySmall),
              if (widget.entry?.enabled == true) Text(text.closeToEdit, style: Theme.of(context).textTheme.bodySmall),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
        FilledButton(
          onPressed: _picking
              ? null
              : () {
                  final slug = WorkspaceCatalogCodec.normalizeSlug(_slug.text);
                  if (_name.text.trim().isEmpty ||
                      RegExp(r'[\x00-\x1f\x7f]').hasMatch(_name.text) ||
                      WorkspaceCatalogCodec.reservedSlugs.contains(slug) ||
                      slug.endsWith('-') ||
                      context.ref.read(workspaceCatalogProvider).entries.any((entry) => entry.id != widget.entry?.id && entry.slug == slug) ||
                      !RegExp(r'^[a-z][a-z0-9-]{0,47}$').hasMatch(_slug.text.trim().toLowerCase()) ||
                      _root.text.trim().isEmpty) {
                    setState(() => _error = text.invalidInput);
                    return;
                  }
                  final source =
                      _picked ??
                      (widget.entry?.source.locator == _root.text
                          ? widget.entry!.source
                          : WorkspaceSource(
                              kind: _root.text.startsWith('content://') ? WorkspaceSourceKind.androidTree : WorkspaceSourceKind.directory,
                              locator: _root.text,
                            ));
                  _accepted = true;
                  Navigator.pop(
                    context,
                    _WorkspaceDraft(
                      _name.text.trim(),
                      slug,
                      source,
                      _visible,
                      newGrant: _picked?.grantId,
                      grants: _grants ?? const IosWorkspaceGrants(),
                    ),
                  );
                },
          child: Text(t.general.save),
        ),
      ],
    );
  }
}
