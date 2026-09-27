import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/pages/api_documentation_page.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/integration_api_publication_provider.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/util/api/api_quota_strings.dart';
import 'package:localsend_app/util/api/api_settings.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/network_address_tags.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:refena_flutter/refena_flutter.dart';

class ApiTab extends StatefulWidget {
  const ApiTab({super.key});
  @override
  State<ApiTab> createState() => _ApiTabState();
}

class _ApiTabState extends State<ApiTab> {
  bool _busy = false;
  int _page = 0;

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.general.confirm)),
          ],
        ),
      ) ??
      false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      await context.ref.notifier(integrationApiPublicationProvider).synchronize();
      if (mounted && context.ref.read(integrationApiPublicationProvider).failed) context.showSnackBar(t.integrationApi.failed);
    } catch (_) {
      if (mounted) context.showSnackBar(t.integrationApi.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle({bool? enabled, bool? requireKey}) async {
    final text = t.integrationApi;
    if (enabled == false && !await _confirm(text.enable, text.disableHint)) return;
    if (requireKey == false && !await _confirm(text.allowAnonymous, text.anonymousHint)) return;
    if (!mounted) return;
    await _run(
      () => context.ref.notifier(integrationApiSettingsProvider).updatePolicy((p) => p.copyWith(enabled: enabled, authRequired: requireKey)),
    );
  }

  Future<void> _editPolicy() async {
    final owner = context.ref.notifier(integrationApiSettingsProvider);
    final publisher = context.ref.notifier(integrationApiPublicationProvider);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PolicyEditor(
        policy: owner.state.policy,
        workspaces: context.ref.read(workspaceCatalogProvider).entries,
        onSave: (result) async {
          await owner.updatePolicy(
            (p) => p.copyWith(
              globalLimits: result.global,
              keyLimits: result.key,
              anonymousLimits: result.anonymous,
              anonymousGrant: result.grant,
              allowedOrigins: result.origins,
            ),
          );
          await publisher.synchronize();
        },
      ),
    );
    if (mounted && publisher.state.failed) context.showSnackBar(t.integrationApi.failed);
  }

  Future<void> _createKey() async {
    final owner = context.ref.notifier(integrationApiSettingsProvider);
    final publisher = context.ref.notifier(integrationApiPublicationProvider);
    final secret = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KeyEditor(
        workspaces: context.ref.read(workspaceCatalogProvider).entries,
        onCreate: (draft) async {
          final secret = await owner.createKey(name: draft.name, grant: draft.grant, expiresAt: draft.expires);
          // A saved key is still handed to its owner if publication remains pending.
          await publisher.synchronize();
          return secret;
        },
      ),
    );
    if (secret == null || !mounted) return;
    await _run(() async {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(t.integrationApi.once),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.integrationApi.onceHint),
                const SizedBox(height: 16),
                SelectableText(
                  secret,
                  key: const ValueKey('api-created-secret'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await _copyApiText(dialogContext, secret);
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t.integrationApi.copy),
            ),
            FilledButton(onPressed: () => Navigator.pop(dialogContext), child: Text(t.integrationApi.close)),
          ],
        ),
      );
    });
  }

  Future<void> _toggleKey(ApiKeyMetadata key) async {
    final copy = ApiQuotaStrings(LocaleSettings.currentLocale.languageTag);
    if (!await _confirm(key.enabled ? copy.pause : copy.resume, key.enabled ? copy.pauseHint : copy.resumeHint) || !mounted) return;
    await _run(() => context.ref.notifier(integrationApiSettingsProvider).setEnabled(key.id, !key.enabled));
  }

  Future<void> _editKeyLimits(ApiKeyMetadata key) async {
    final policy = context.ref.read(integrationApiSettingsProvider).policy;
    final settings = context.ref.notifier(integrationApiSettingsProvider);
    final publication = context.ref.notifier(integrationApiPublicationProvider);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KeyLimitsEditor(
        metadata: key,
        defaults: policy.keyLimits,
        onSave: (limits) async {
          await settings.setKeyLimits(key.id, limits);
          await publication.synchronize();
        },
      ),
    );
  }

  Future<void> _rename(ApiKeyMetadata key) async {
    final controller = TextEditingController(text: key.name);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.general.edit),
          content: TextField(
            controller: controller,
            maxLength: 64,
            autofocus: true,
            decoration: InputDecoration(labelText: t.integrationApi.keyName),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) Navigator.pop(context, controller.text);
              },
              child: Text(t.general.save),
            ),
          ],
        ),
      );
      if (name != null && mounted) await _run(() => context.ref.notifier(integrationApiSettingsProvider).rename(key.id, name));
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context);
    final text = t.integrationApi;
    final settings = context.watch(integrationApiSettingsProvider);
    final publication = context.watch(integrationApiPublicationProvider);
    final server = context.watch(serverProvider);
    final network = context.watch(localIpProvider);
    final pending = _busy || settings.saving || publication.busy || !settings.initialized;
    final usable = !pending && !settings.corrupt;
    final runtime = publication.runtime;
    final applied = publication.appliedGeneration == settings.generation && !publication.failed;
    final page = math.min(_page, math.max(0, (settings.keys.length - 1) ~/ 20));
    final keys = settings.keys.skip(page * 20).take(20);
    final addresses = network.addresses.where((a) => a.hasNonLinkLocalAddress).toList();
    final scheme = server?.https == true ? 'https' : 'http';
    final removedLive = runtime?.keyIds.difference(settings.keys.map((k) => k.id).toSet()).isNotEmpty ?? false;
    return ResponsiveListView(
      maxWidth: 840,
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.api, size: 24),
                const SizedBox(width: 10),
                Flexible(child: Text(text.title, style: Theme.of(context).textTheme.headlineSmall)),
              ],
            ),
            StatusTag(label: text.readOnly),
          ],
        ),
        const SizedBox(height: 6),
        Text(text.subtitle, style: Theme.of(context).textTheme.bodySmall),
        if (![AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk].contains(LocaleSettings.currentLocale))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: StatusTag(label: text.fallback),
          ),
        const SizedBox(height: 16),
        _Section(
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StatusTag(
                  key: const ValueKey('api-live-state'),
                  label: publication.busy
                      ? text.syncing
                      : publication.failed
                      ? text.previous
                      : server == null
                      ? text.waiting
                      : runtime == null
                      ? text.unconfirmed
                      : runtime.policy.enabled
                      ? text.live
                      : text.off,
                  icon: publication.failed ? Icons.sync_problem : Icons.circle,
                  foregroundColor: publication.failed ? Theme.of(context).colorScheme.error : null,
                ),
                if (server != null) StatusTag(label: server.https ? 'HTTPS · TLS' : 'HTTP'),
                if (runtime != null) StatusTag(label: '${text.concurrent}: ${runtime.activeResponses}'),
                StatusTag(
                  label: text.refresh,
                  icon: Icons.refresh,
                  onTap: pending ? null : () => _run(() => context.ref.notifier(integrationApiPublicationProvider).synchronize(refresh: true)),
                ),
                if (server == null)
                  StatusTag(
                    label: text.startService,
                    icon: Icons.play_arrow,
                    onTap: usable ? () => _run(() => context.ref.notifier(serverProvider).startServerFromSettings()) : null,
                  ),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('api-enable'),
              contentPadding: EdgeInsets.zero,
              title: Text(text.enable),
              value: settings.policy.enabled,
              onChanged: usable ? (value) => _toggle(enabled: value) : null,
            ),
            SwitchListTile(
              key: const ValueKey('api-auth'),
              contentPadding: EdgeInsets.zero,
              title: Text(text.requireKey),
              value: settings.policy.authRequired,
              onChanged: usable ? (value) => _toggle(requireKey: value) : null,
            ),
            Text(text.isolation, style: Theme.of(context).textTheme.bodySmall),
            if (publication.observedAt != null)
              Text(
                '${text.updated}: ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(publication.observedAt!))}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            if (settings.policy.enabled && !applied && !publication.busy) Padding(padding: const EdgeInsets.only(top: 8), child: Text(text.waiting)),
            if (publication.failed || settings.failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(settings.corrupt ? text.corrupt : text.failed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (removedLive)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(text.removedLive, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (settings.corrupt)
              Wrap(
                spacing: 8,
                children: [
                  StatusTag(
                    label: text.refresh,
                    onTap: pending ? null : () => _run(() => context.ref.notifier(integrationApiSettingsProvider).retryLoad()),
                  ),
                  StatusTag(
                    label: text.reset,
                    onTap: pending
                        ? null
                        : () async {
                            if (await _confirm(text.reset, text.resetHint) && mounted) {
                              await _run(() => context.ref.notifier(integrationApiSettingsProvider).reset());
                            }
                          },
                  ),
                ],
              ),
          ],
        ),
        if (server != null && runtime?.policy.enabled == true)
          _Section(
            title: text.addresses,
            children: [
              Text(text.addressHint, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              for (final address in addresses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      NetworkAddressTags(address: address),
                      const SizedBox(height: 4),
                      _Address(
                        url: Uri(scheme: scheme, host: address.address, port: server.port, path: '/api/legnasend/v1/integration').toString(),
                      ),
                    ],
                  ),
                ),
              if (addresses.isEmpty)
                _Address(
                  url: Uri(scheme: scheme, host: '127.0.0.1', port: server.port, path: '/api/legnasend/v1/integration').toString(),
                ),
            ],
          ),
        _Section(
          title: text.policy,
          trailing: StatusTag(label: text.editPolicy, icon: Icons.tune, onTap: usable ? _editPolicy : null),
          children: [
            Text(text.fixedWindow, style: Theme.of(context).textTheme.bodySmall),
            Text(ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).zeroHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            for (final row in [
              (text.global, settings.policy.globalLimits),
              (text.perKey, settings.policy.keyLimits),
              (text.anonymous, settings.policy.anonymousLimits),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(row.$1),
                    StatusTag(label: '${ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).value(row.$2.perSecond)} / s'),
                    StatusTag(label: '${ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).value(row.$2.perMinute)} / min'),
                    StatusTag(label: '${text.concurrent}: ${ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).value(row.$2.concurrent)}'),
                  ],
                ),
              ),
            if (!settings.policy.authRequired) Text(text.anonymousHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        _Section(
          title: '${text.keys} · ${settings.keys.length}',
          trailing: StatusTag(
            key: const ValueKey('api-create'),
            label: text.createKey,
            icon: Icons.add,
            onTap: usable && settings.keys.length < 128 ? _createKey : null,
          ),
          children: [
            if (settings.keys.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(text.empty)),
            for (final key in keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(key.name, style: Theme.of(context).textTheme.titleSmall)),
                        IconButton(
                          tooltip: t.general.edit,
                          onPressed: usable ? () => _rename(key) : null,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('api-revoke-${key.id}'),
                          tooltip: text.revoke,
                          onPressed: usable
                              ? () async {
                                  if (await _confirm(text.revoke, text.revokeHint) && mounted) {
                                    await _run(() => context.ref.notifier(integrationApiSettingsProvider).revoke(key.id));
                                  }
                                }
                              : null,
                          icon: const Icon(Icons.key_off_outlined, size: 18),
                        ),
                      ],
                    ),
                    SelectableText(key.id, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        StatusTag(
                          label: key.expired
                              ? text.expired
                              : !key.enabled
                              ? (applied
                                    ? ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).paused
                                    : ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).pausePending)
                              : applied && runtime?.policy.enabled == true && runtime!.keyIds.contains(key.id)
                              ? text.live
                              : text.pendingKey,
                        ),
                        StatusTag(
                          label: key.expiresAt == null
                              ? text.never
                              : MaterialLocalizations.of(context).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(key.expiresAt! * 1000)),
                        ),
                        StatusTag(
                          key: ValueKey('api-key-toggle-${key.id}'),
                          label: key.enabled
                              ? ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).pause
                              : ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).resume,
                          icon: key.enabled ? Icons.pause : Icons.play_arrow,
                          onTap: usable ? () => _toggleKey(key) : null,
                        ),
                        StatusTag(
                          key: ValueKey('api-key-limits-${key.id}'),
                          label: key.limits == null
                              ? ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).inherited
                              : ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).custom,
                          icon: Icons.tune,
                          onTap: usable ? () => _editKeyLimits(key) : null,
                        ),
                        for (final scope in key.grant.scopes) StatusTag(label: _scopeLabel(scope)),
                        StatusTag(
                          label: key.grant.workspaces.contains('*') ? text.allWorkspaces : '${text.selectWorkspaces}: ${key.grant.workspaces.length}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (settings.keys.length > 20)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusTag(label: text.previousPage, onTap: page > 0 ? () => setState(() => _page = page - 1) : null),
                  Text('${page + 1} / ${(settings.keys.length / 20).ceil()}'),
                  StatusTag(label: text.more, onTap: (page + 1) * 20 < settings.keys.length ? () => setState(() => _page = page + 1) : null),
                ],
              ),
          ],
        ),
        _Section(
          title: text.documentation,
          trailing: StatusTag(
            key: const ValueKey('api-documentation'),
            label: text.documentation,
            icon: Icons.menu_book_outlined,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApiDocumentationPage())),
          ),
          children: [
            Text(text.documentationHint),
            const SizedBox(height: 12),
            StatusTag(
              key: const ValueKey('api-explorer'),
              label: t.apiExplorer.title,
              icon: Icons.code,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApiExplorerPage())),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(text.nextStage, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

Future<void> _copyApiText(BuildContext context, String value) async {
  try {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) context.showSnackBar(t.integrationApi.copied);
  } catch (_) {
    if (context.mounted) context.showSnackBar(t.integrationApi.copyFailed);
  }
}

class _Address extends StatelessWidget {
  final String url;
  const _Address({required this.url});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: SelectableText(url, style: Theme.of(context).textTheme.bodySmall)),
      IconButton(
        tooltip: t.integrationApi.copy,
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () async {
          await _copyApiText(context, url);
        },
      ),
    ],
  );
}

class _Section extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  const _Section({this.title, this.trailing, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card.filled(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(title!, style: Theme.of(context).textTheme.titleMedium),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 10),
            ],
            ...children,
          ],
        ),
      ),
    ),
  );
}

String _scopeLabel(ApiScope scope) => switch (scope) {
  ApiScope.service => t.integrationApi.scopeService,
  ApiScope.workspaces => t.integrationApi.scopeWorkspaces,
  ApiScope.files => t.integrationApi.scopeFiles,
  ApiScope.upload => t.integrationApi.scopeUpload,
  ApiScope.manage => t.integrationApi.scopeManage,
  ApiScope.requests => t.integrationApi.scopeRequests,
  _ => ApiTransferStrings(LocaleSettings.currentLocale.languageTag).scope(scope),
};

class _GrantPicker extends StatelessWidget {
  final ApiGrant grant;
  final List<DirectoryWorkspace> workspaces;
  final ValueChanged<ApiGrant> onChanged;
  final bool anonymous;
  const _GrantPicker({required this.grant, required this.workspaces, required this.onChanged, this.anonymous = false});
  @override
  Widget build(BuildContext context) {
    final all = grant.workspaces.contains('*');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.integrationApi.permissions, style: Theme.of(context).textTheme.titleSmall),
        for (final scope in ApiScope.values.where((s) => !anonymous || s.allowsAnonymous))
          CheckboxListTile(
            key: ValueKey('api-scope-${scope.name}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(_scopeLabel(scope)),
            value: grant.scopes.contains(scope),
            onChanged: (value) => onChanged(
              ApiGrant(scopes: value == true ? [...grant.scopes, scope] : grant.scopes.where((s) => s != scope), workspaces: grant.workspaces),
            ),
          ),
        if (!anonymous) Text(ApiTransferStrings(TranslationProvider.of(context).locale.languageTag).hint),
        Text(t.integrationApi.selectWorkspaces, style: Theme.of(context).textTheme.titleSmall),
        CheckboxListTile(
          key: const ValueKey('api-all-workspaces'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(t.integrationApi.allWorkspaces),
          value: all,
          onChanged: (value) => onChanged(ApiGrant(scopes: grant.scopes, workspaces: value == true ? ['*'] : [])),
        ),
        if (!all && workspaces.isNotEmpty)
          SizedBox(
            height: math.min(176, workspaces.length * 52).toDouble(),
            child: ListView.builder(
              itemCount: workspaces.length,
              itemBuilder: (context, index) {
                final workspace = workspaces[index];
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(workspace.name),
                  subtitle: Text('/${workspace.slug}/'),
                  value: grant.workspaces.contains(workspace.id),
                  onChanged: (value) => onChanged(
                    ApiGrant(
                      scopes: grant.scopes,
                      workspaces: value == true ? [...grant.workspaces, workspace.id] : grant.workspaces.where((id) => id != workspace.id),
                    ),
                  ),
                );
              },
            ),
          ),
        Text(anonymous ? t.integrationApi.anonymousHint : t.integrationApi.grantHint, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _KeyDraft {
  final String name;
  final ApiGrant grant;
  final int? expires;
  _KeyDraft(this.name, this.grant, this.expires);
}

class _KeyEditor extends StatefulWidget {
  final List<DirectoryWorkspace> workspaces;
  final Future<String> Function(_KeyDraft) onCreate;
  const _KeyEditor({required this.workspaces, required this.onCreate});
  @override
  State<_KeyEditor> createState() => _KeyEditorState();
}

class _KeyEditorState extends State<_KeyEditor> {
  final _name = TextEditingController();
  ApiGrant _grant = ApiGrant(scopes: [ApiScope.service, ApiScope.workspaces, ApiScope.files], workspaces: []);
  int _days = 30;
  int _error = 0;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!isApiKeyNameValid(_name.text) ||
        _grant.scopes.isEmpty ||
        (_grant.scopes.any((s) => s.requiresGlobal) && !_grant.workspaces.contains('*')) ||
        (_grant.workspaces.isEmpty &&
            (_grant.scopes.contains(ApiScope.workspaces) ||
                _grant.scopes.contains(ApiScope.files) ||
                _grant.scopes.contains(ApiScope.upload) ||
                _grant.scopes.contains(ApiScope.manage)))) {
      setState(() => _error = 1);
      return;
    }
    setState(() {
      _busy = true;
      _error = 0;
    });
    try {
      final secret = await widget.onCreate(
        _KeyDraft(_name.text, _grant, _days == 0 ? null : DateTime.now().add(Duration(days: _days)).millisecondsSinceEpoch ~/ 1000),
      );
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context, secret);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 2;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(t.integrationApi.createKey),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('api-key-name'),
              controller: _name,
              enabled: !_busy,
              autofocus: true,
              maxLength: 64,
              decoration: InputDecoration(labelText: t.integrationApi.keyName),
            ),
            IgnorePointer(
              ignoring: _busy,
              child: ExcludeFocus(
                excluding: _busy,
                child: _GrantPicker(grant: _grant, workspaces: widget.workspaces, onChanged: (grant) => setState(() => _grant = grant)),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _days,
              decoration: InputDecoration(labelText: t.integrationApi.expiry),
              items: [
                DropdownMenuItem(value: 30, child: Text(t.integrationApi.days30)),
                DropdownMenuItem(value: 90, child: Text(t.integrationApi.days90)),
                DropdownMenuItem(value: 0, child: Text(t.integrationApi.never)),
              ],
              onChanged: _busy ? null : (value) => setState(() => _days = value ?? 30),
            ),
            if (_error != 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error == 1 ? t.integrationApi.invalid : t.integrationApi.failed,
                  key: const ValueKey('api-key-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.general.cancel)),
        FilledButton(
          key: const ValueKey('api-generate-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? t.integrationApi.syncing : t.integrationApi.createKey),
        ),
      ],
    ),
  );
}

class _PolicyDraft {
  final ApiLimits global, key, anonymous;
  final ApiGrant grant;
  final List<String> origins;
  _PolicyDraft(this.global, this.key, this.anonymous, this.grant, this.origins);
}

class _PolicyEditor extends StatefulWidget {
  final ApiPolicy policy;
  final List<DirectoryWorkspace> workspaces;
  final Future<void> Function(_PolicyDraft) onSave;
  const _PolicyEditor({required this.policy, required this.workspaces, required this.onSave});
  @override
  State<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends State<_PolicyEditor> {
  late final List<List<TextEditingController>> _limits;
  late final TextEditingController _origins;
  late ApiGrant _grant;
  int _error = 0;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _limits = [
      for (final limits in [widget.policy.globalLimits, widget.policy.keyLimits, widget.policy.anonymousLimits])
        [
          for (final value in [limits.perSecond, limits.perMinute, limits.concurrent]) TextEditingController(text: '$value'),
        ],
    ];
    _origins = TextEditingController(text: widget.policy.allowedOrigins.join('\n'));
    _grant = widget.policy.anonymousGrant;
  }

  @override
  void dispose() {
    for (final group in _limits) {
      for (final field in group) {
        field.dispose();
      }
    }
    _origins.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    late _PolicyDraft draft;
    try {
      final limits = [for (final fields in _limits) ApiLimits(int.parse(fields[0].text), int.parse(fields[1].text), int.parse(fields[2].text))];
      final origins = _origins.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      widget.policy.copyWith(
        globalLimits: limits[0],
        keyLimits: limits[1],
        anonymousLimits: limits[2],
        anonymousGrant: _grant,
        allowedOrigins: origins,
      );
      draft = _PolicyDraft(limits[0], limits[1], limits[2], _grant, origins);
    } catch (_) {
      setState(() => _error = 1);
      return;
    }
    setState(() {
      _busy = true;
      _error = 0;
    });
    try {
      await widget.onSave(draft);
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 2;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = t.integrationApi;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(text.policy),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text.fixedWindow, style: Theme.of(context).textTheme.bodySmall),
              Text(ApiQuotaStrings(LocaleSettings.currentLocale.languageTag).zeroHint, style: Theme.of(context).textTheme.bodySmall),
              for (var i = 0; i < 3; i++) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: Text([text.global, text.perKey, text.anonymous][i], style: Theme.of(context).textTheme.titleSmall),
                ),
                Builder(
                  builder: (context) {
                    // AlertDialog measures intrinsic height, so avoid a LayoutBuilder.
                    // Account for the explicit dialog insets/content padding instead of
                    // treating the full window width as the input row's available width.
                    final media = MediaQuery.of(context);
                    final contentWidth = math.min(560.0, media.size.width - media.padding.horizontal - media.viewInsets.horizontal - 96);
                    // Android can scale small text nonlinearly; scale the actual
                    // caption/value sizes, not a fictitious 132px font size.
                    final textScale = math.max(media.textScaler.scale(12) / 12, media.textScaler.scale(16) / 16);
                    final vertical = contentWidth < 132 * textScale * 3 + 24;
                    final labels = [text.second, text.minute, text.concurrent];
                    final group = [text.global, text.perKey, text.anonymous][i];
                    final fields = [
                      for (var j = 0; j < 3; j++)
                        _QuotaField(
                          id: 'api-limit-$i-$j',
                          label: labels[j],
                          semanticLabel: '$group · ${labels[j]}',
                          controller: _limits[i][j],
                          enabled: !_busy,
                        ),
                    ];
                    return vertical
                        ? Column(
                            children: [for (final field in fields) Padding(padding: const EdgeInsets.only(bottom: 12), child: field)],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var j = 0; j < 3; j++)
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(right: j < 2 ? 12 : 0),
                                    child: fields[j],
                                  ),
                                ),
                            ],
                          );
                  },
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _origins,
                enabled: !_busy,
                minLines: 2,
                maxLines: 4,
                maxLength: 8200,
                decoration: InputDecoration(
                  labelText: text.origins,
                  helper: Text(text.originsHint),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              IgnorePointer(
                ignoring: _busy,
                child: ExcludeFocus(
                  excluding: _busy,
                  child: _GrantPicker(
                    grant: _grant,
                    anonymous: true,
                    workspaces: widget.workspaces,
                    onChanged: (grant) => setState(() => _grant = grant),
                  ),
                ),
              ),
              if (_error != 0)
                Text(
                  _error == 1 ? text.invalid : text.failed,
                  key: const ValueKey('api-policy-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.general.cancel)),
          FilledButton(key: const ValueKey('api-policy-save'), onPressed: _busy ? null : _submit, child: Text(_busy ? text.syncing : t.general.save)),
        ],
      ),
    );
  }
}

/// Explicit labels keep compact number inputs independent of the app-wide
/// zero-vertical-padding theme and avoid animated floating-label collisions.
class _QuotaField extends StatelessWidget {
  final String id;
  final String label;
  final String semanticLabel;
  final TextEditingController controller;
  final bool enabled;
  const _QuotaField({required this.id, required this.label, required this.semanticLabel, required this.controller, required this.enabled});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExcludeSemantics(
        child: Text(label, key: ValueKey('$id-label'), style: Theme.of(context).textTheme.labelMedium),
      ),
      const SizedBox(height: 6),
      Semantics(
        label: semanticLabel,
        child: TextField(
          key: ValueKey(id),
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          decoration: const InputDecoration(
            isDense: true,
            constraints: BoxConstraints(minHeight: 48),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ),
    ],
  );
}

class _KeyLimitsEditor extends StatefulWidget {
  final ApiKeyMetadata metadata;
  final ApiLimits defaults;
  final Future<void> Function(ApiLimits?) onSave;
  const _KeyLimitsEditor({required this.metadata, required this.defaults, required this.onSave});
  @override
  State<_KeyLimitsEditor> createState() => _KeyLimitsEditorState();
}

class _KeyLimitsEditorState extends State<_KeyLimitsEditor> {
  late bool _inherit;
  late final List<TextEditingController> _fields;
  bool _busy = false;
  int _error = 0;
  @override
  void initState() {
    super.initState();
    _inherit = widget.metadata.limits == null;
    final limits = widget.metadata.limits ?? widget.defaults;
    _fields = [
      for (final n in [limits.perSecond, limits.perMinute, limits.concurrent]) TextEditingController(text: '$n'),
    ];
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    ApiLimits? limits;
    try {
      if (!_inherit) {
        limits = ApiLimits(int.parse(_fields[0].text), int.parse(_fields[1].text), int.parse(_fields[2].text));
        limits.validate();
      }
    } catch (_) {
      setState(() => _error = 1);
      return;
    }
    setState(() {
      _busy = true;
      _error = 0;
    });
    try {
      await widget.onSave(limits);
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 2;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = ApiQuotaStrings(LocaleSettings.currentLocale.languageTag), text = t.integrationApi;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(copy.limits),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.metadata.name),
              const SizedBox(height: 8),
              Text(copy.limitsHint),
              const SizedBox(height: 8),
              Text(copy.zeroHint),
              SwitchListTile.adaptive(
                key: const ValueKey('api-key-inherit'),
                contentPadding: EdgeInsets.zero,
                title: Text(copy.inherit),
                value: _inherit,
                onChanged: _busy ? null : (value) => setState(() => _inherit = value),
              ),
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _QuotaField(
                    id: 'api-key-limit-$i',
                    label: [text.second, text.minute, text.concurrent][i],
                    semanticLabel: [text.second, text.minute, text.concurrent][i],
                    controller: _fields[i],
                    enabled: !_busy && !_inherit,
                  ),
                ),
              if (_error != 0)
                Text(
                  _error == 1 ? text.invalid : text.failed,
                  key: const ValueKey('api-key-limits-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.general.cancel)),
          FilledButton(
            key: const ValueKey('api-key-limits-save'),
            onPressed: _busy ? null : _save,
            child: Text(_busy ? text.syncing : t.general.save),
          ),
        ],
      ),
    );
  }
}
