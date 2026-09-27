import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_documentation_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_explorer.dart';
import 'package:localsend_app/util/api/api_history_control.dart';
import 'package:localsend_app/util/api/api_history_export.dart';
import 'package:localsend_app/util/api/api_key_strings.dart';
import 'package:localsend_app/util/api/api_management_strings.dart';
import 'package:localsend_app/util/api/api_source_strings.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';
import 'package:localsend_app/util/api/api_upload_source.dart';
import 'package:localsend_app/util/api/api_upload_strings.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/api/api_history_control_button.dart';
import 'package:localsend_app/widget/api/api_history_export_button.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

class ApiExplorerPage extends StatefulWidget {
  final Future<ApiUploadSource?> Function()? pickUploadSource;
  const ApiExplorerPage({super.key, this.pickUploadSource});
  @override
  State<ApiExplorerPage> createState() => _ApiExplorerPageState();
}

class _ApiExplorerPageState extends State<ApiExplorerPage> {
  final _search = TextEditingController(), _token = TextEditingController();
  final _transferDrafts = <String, Map<String, String>>{};
  final _fields = <String, TextEditingController>{};
  ApiCatalog? _catalog;
  String? _asset, _selected;
  String _group = 'all', _query = '';
  bool _busy = false, _loadFailed = false, _choosing = false, _confirming = false;
  ApiUploadSource? _uploadSource;
  SourceCacheLease? _uploadSourceLease;
  ApiTransferStrings get _transferText => ApiTransferStrings(TranslationProvider.of(context).locale.languageTag);
  ApiSourceStrings get _sourceText => ApiSourceStrings(TranslationProvider.of(context).locale.languageTag);
  ApiManagementStrings get _managementText => ApiManagementStrings(TranslationProvider.of(context).locale.languageTag);
  ApiUploadStrings get _uploadText => ApiUploadStrings(TranslationProvider.of(context).locale.languageTag);
  bool _exportBusy = false;
  bool get _blocked => _exportBusy || _busy || _choosing || _confirming;
  String? _error;
  Map<String, dynamic>? _result;
  int _epoch = 0;
  Future<void> _load(String asset) async {
    _asset = asset;
    final epoch = ++_epoch;
    try {
      final source = await DefaultAssetBundle.of(context).loadString(asset, cache: false);
      if (!mounted || epoch != _epoch) return;
      final next = ApiCatalog.parse(source);
      setState(() {
        _catalog = next;
        _loadFailed = false;
        _selected ??= 'getStatus';
      });
    } catch (_) {
      if (mounted && epoch == _epoch) setState(() => _loadFailed = true);
    }
  }

  void _select(ApiOperation operation) {
    if (_catalog?.operations.any((op) => op.id == _selected && (op.isTransfer || op.isKeys)) == true) {
      _transferDrafts[_selected!] = Map.of(_values);
    }
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    for (final p in operation.inputParameters) {
      _fields[p.name] = TextEditingController(text: operation.defaults()[p.name] ?? '');
    }
    final draft = _transferDrafts[operation.id];
    if ((operation.isTransfer || operation.isKeys) && draft != null) {
      for (final entry in draft.entries) {
        _fields.putIfAbsent(entry.key, TextEditingController.new).text = entry.value;
      }
    }
    if (operation.hasRequestId) {
      _fields.putIfAbsent('body.requestId', () => TextEditingController(text: const Uuid().v4()));
    }
    _uploadSourceLease?.release();
    _uploadSourceLease = null;
    setState(() {
      _selected = operation.id;
      _uploadSource = null;
      _error = null;
      _result = null;
    });
  }

  Map<String, String> get _values => {for (final entry in _fields.entries) entry.key: entry.value.text};
  Future<void> _execute(ApiOperation operation) async {
    if (_blocked) return;
    if (!operation.valid(_values)) {
      setState(
        () => _error =
            operation.isManagement && _values['action'] == 'update' && ['name', 'visible', 'allowUpload'].every((key) => (_values[key] ?? '').isEmpty)
            ? _managementText.emptyUpdate
            : t.apiExplorer.invalid,
      );
      return;
    }
    final values = Map<String, String>.of(_values);
    final source = _uploadSource;
    if (operation.isUpload && values['directory'] != 'true' && source == null) {
      setState(() => _error = _uploadText.fileRequired);
      return;
    }
    final server = context.ref.notifier(serverProvider), generation = context.ref.notifier(serverProvider).generation;
    final token = _token.text.trim();
    if (operation.isUpload) {
      setState(() => _confirming = true);
      final copy = _uploadText;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-upload-confirmation'),
          title: Text(copy.confirmTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(copy.confirmHint),
                const SizedBox(height: 12),
                Text('${copy.destination}: ${values['workspaceId']} / ${values['path']}'),
                if ((values['parent'] ?? '').isNotEmpty) Text('${copy.parent}: ${values['parent']}'),
                Text(values['directory'] == 'true' ? copy.empty : '${copy.file}: ${source!.name} (${source.size} B)'),
              ],
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('api-upload-decline'), onPressed: () => Navigator.pop(context, false), child: Text(copy.cancel)),
            FilledButton(key: const ValueKey('api-upload-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(copy.confirm)),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true) return;
    }
    if (operation.isManagement) {
      setState(() => _confirming = true);
      final copy = _managementText;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-management-confirmation'),
          title: Text(copy.confirmTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${copy.action}: ${operation.isCreate ? _sourceText.create : copy.actionLabel(values['action']!)}'),
                const SizedBox(height: 12),
                Text('${copy.target}: ${operation.isCreate ? values['body.name'] : values['workspaceId']}'),
                if (!operation.isCreate) Text('generation: ${values['generation']}'),
                if (operation.isCreate || values['action'] == 'configure') ...[
                  Text(operation.isCreate ? _sourceText.create : _sourceText.configure),
                  if ((values['body.sourceId'] ?? '').isNotEmpty) Text('${_sourceText.sourceId}: ${values['body.sourceId']}'),
                  if ((values['body.slug'] ?? '').isNotEmpty) Text('${_sourceText.slug}: ${values['body.slug']}'),
                  if ((values['body.visible'] ?? '').isNotEmpty) Text('${copy.visible}: ${values['body.visible'] == 'true' ? copy.yes : copy.no}'),
                  if ((values['body.allowUpload'] ?? '').isNotEmpty)
                    Text('${copy.allowUpload}: ${values['body.allowUpload'] == 'true' ? copy.yes : copy.no}'),
                ],
                if (values['action'] == 'password') Text(values['body.clear'] == 'true' ? _sourceText.clear : _sourceText.password),
                if (values['action'] == 'update') ...[
                  const SizedBox(height: 12),
                  Text(copy.changes),
                  if ((values['name'] ?? '').isNotEmpty) Text('${copy.name}: ${values['name']}'),
                  if ((values['visible'] ?? '').isNotEmpty) Text('${copy.visible}: ${values['visible'] == 'true' ? copy.yes : copy.no}'),
                  if ((values['allowUpload'] ?? '').isNotEmpty) Text('${copy.allowUpload}: ${values['allowUpload'] == 'true' ? copy.yes : copy.no}'),
                ],
                const SizedBox(height: 12),
                Text(values['action'] == 'destroy' ? copy.destroy : copy.hint),
              ],
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('api-management-decline'), onPressed: () => Navigator.pop(context, false), child: Text(copy.cancel)),
            FilledButton(key: const ValueKey('api-management-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(copy.confirm)),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true) return;
    }
    if (operation.isKeyMutation || operation.isHistoryControl) {
      final copy = ApiKeyStrings(TranslationProvider.of(context).locale.languageTag);
      final historyCopy = ApiHistoryControlStrings(TranslationProvider.of(context).locale.languageTag);
      setState(() => _confirming = true);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-key-confirmation'),
          title: Text(operation.isHistoryControl ? historyCopy.title : copy.confirm),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(operation.summary),
                Text(operation.isHistoryControl ? historyCopy.explanation : copy.hint),
                for (final field in operation.bodyFields(values)) Text('${copy.field(field)}: ${values['body.$field'] ?? ''}'),
                if (values['keyId'] != null) Text('keyId: ${values['keyId']}'),
              ],
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('api-key-decline'), onPressed: () => Navigator.pop(context, false), child: Text(copy.cancel)),
            FilledButton(key: const ValueKey('api-key-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(copy.confirm)),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (accepted != true) return;
    }
    if (operation.isTransferMutation ||
        operation.isHostMutation ||
        operation.isNativeTaskMutation ||
        operation.isPreviewLease ||
        operation.isArchiveSelection) {
      setState(() => _confirming = true);
      final copy = _transferText;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-transfer-confirmation'),
          title: Text(copy.confirm),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(copy.action(operation.id)),
                const SizedBox(height: 12),
                if (values['taskId'] != null) Text('taskId: ${values['taskId']}'),
                if (values['workspaceId'] != null) Text('workspaceId: ${values['workspaceId']}'),
                if (values['transferId'] != null) Text('transferId: ${values['transferId']}'),
                for (final field in operation.bodyFields(values))
                  if ((values['body.$field'] ?? '').isNotEmpty)
                    Text(
                      '${copy.field(field)}: ${['files', 'ids'].contains(field) ? (values['body.$field']!.length > 512 ? '${values['body.$field']!.substring(0, 512)}…' : values['body.$field']) : values['body.$field']}',
                    ),
                if (operation.hasRequestId) Text(copy.requestHint),
              ],
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('api-transfer-decline'), onPressed: () => Navigator.pop(context, false), child: Text(copy.cancel)),
            FilledButton(key: const ValueKey('api-transfer-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(copy.confirm)),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true) return;
    }
    final request = operation.request(values, token, uploadSource: source?.requestFields);
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    // The request retains its own lease: navigating away releases only the
    // draft, not the source still being streamed by the server isolate.
    final requestLease = operation.isUpload && source != null ? await context.ref.read(sourceCacheLeaseProvider).acquire() : null;
    try {
      if (!mounted) return;
      final result = await server.integrationApiRequest(expectedGeneration: generation, request: request);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      if (operation.id == 'createKey' && decoded['status'] == 201 && decoded['body'] is String) {
        final body = jsonDecode(decoded['body'] as String) as Map<String, dynamic>;
        final secret = body.remove('secret');
        decoded['body'] = jsonEncode(body);
        if (secret is String && mounted && epoch == _epoch) {
          setState(() {
            _busy = false;
            _confirming = true;
          });
          final controller = TextEditingController(text: secret);
          final copy = ApiKeyStrings(TranslationProvider.of(context).locale.languageTag);
          try {
            await showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                key: const ValueKey('api-key-secret'),
                title: Text(copy.secretTitle),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(copy.secretHint),
                      TextField(
                        key: const ValueKey('api-key-secret-value'),
                        controller: controller,
                        readOnly: true,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () => Clipboard.setData(ClipboardData(text: controller.text)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [TextButton(key: const ValueKey('api-key-secret-close'), onPressed: () => Navigator.pop(context), child: Text(copy.close))],
              ),
            );
          } finally {
            controller.clear();
            controller.dispose();
            if (mounted) setState(() => _confirming = false);
          }
        }
      }
      if (mounted && epoch == _epoch) setState(() => _result = decoded);
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(
          () => _error = operation.isKeyMutation
              ? ApiKeyStrings(TranslationProvider.of(context).locale.languageTag).unknown
              : operation.isManagement
              ? _managementText.unknown
              : operation.isNativeTaskMutation
              ? _transferText.nativeUnknown
              : operation.isHostMutation
              ? _transferText.hostUnknown
              : operation.isTransferMutation
              ? _transferText.unknown
              : t.apiExplorer.failed,
        );
      }
    } finally {
      requestLease?.release();
      if (mounted) _fields['body.password']?.clear();
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _newTransferRequest() async {
    if (_blocked) return;
    setState(() => _confirming = true);
    final selected = _selected;
    final copy = _transferText;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('api-transfer-new-request-confirmation'),
        title: Text(copy.newRequest),
        content: Text(copy.requestHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(copy.cancel)),
          FilledButton(
            key: const ValueKey('api-transfer-new-request-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(copy.confirm),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() {
      _confirming = false;
      if (confirmed == true && selected == _selected) {
        _fields.putIfAbsent('body.requestId', TextEditingController.new).text = const Uuid().v4();
        _error = null;
        _result = null;
      }
    });
  }

  Widget _managementChoice(ApiParameter parameter) {
    final copy = _managementText;
    final controller = _fields.putIfAbsent(parameter.name, TextEditingController.new);
    final action = parameter.name == 'action';
    final options = action
        ? {
            '': copy.action,
            for (final value in ['update', 'enable', 'disable', 'validate', 'destroy', 'configure', 'password']) value: copy.actionLabel(value),
          }
        : {'': copy.unchanged, 'true': copy.yes, 'false': copy.no};
    return InputDecorator(
      decoration: InputDecoration(
        labelText: action
            ? copy.action
            : parameter.name == 'visible'
            ? copy.visible
            : copy.allowUpload,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('api-param-${parameter.name}'),
          isExpanded: true,
          value: controller.text,
          items: [
            for (final entry in options.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _blocked
              ? null
              : (value) => setState(() {
                  if (action) _fields['body.password']?.clear();
                  controller.text = value ?? '';
                  _error = null;
                  if (action && value != 'update') {
                    for (final key in ['name', 'visible', 'allowUpload']) {
                      _fields[key]?.clear();
                    }
                  }
                }),
        ),
      ),
    );
  }

  Future<void> _pickUpload() async {
    if (_blocked) return;
    final selected = _selected;
    setState(() {
      _choosing = true;
      _error = null;
    });
    SourceCacheLease? pickedLease = await context.ref.read(sourceCacheLeaseProvider).acquire();
    try {
      if (!mounted) return;
      final source = await (widget.pickUploadSource ?? pickApiUploadSource)();
      if (!mounted || selected != _selected || source == null) return;
      if (source.path.isEmpty || source.size < 0 || source.name.isEmpty) throw StateError('Invalid source');
      _uploadSourceLease?.release();
      _uploadSourceLease = pickedLease;
      pickedLease = null;
      setState(() {
        _uploadSource = source;
        final destination = _fields['path'];
        if (destination != null && destination.text.isEmpty) destination.text = source.name;
      });
    } on FormatException {
      if (mounted) setState(() => _error = _uploadText.single);
    } catch (_) {
      if (mounted) setState(() => _error = _uploadText.chooseFailed);
    } finally {
      pickedLease?.release();
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<ApiHistorySnapshot> _loadHistory() async {
    final service = context.ref.notifier(serverProvider), epoch = service.generation;
    final token = _token.text.trim();
    return collectApiHistory((after) async {
      final result =
          jsonDecode(
                await service.integrationApiRequest(
                  expectedGeneration: epoch,
                  request: jsonEncode({
                    'operation': 'listRequests',
                    'token': token,
                    'parameters': {'after': '$after', 'limit': '100'},
                  }),
                ),
              )
              as Map<String, dynamic>;
      if (result['status'] != 200 || result['truncated'] == true || result['binary'] == true) throw StateError('History capture failed');
      return jsonDecode(result['body'] as String) as Map<String, dynamic>;
    });
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) context.showSnackBar(t.integrationApi.copied);
    } catch (_) {
      if (mounted) context.showSnackBar(t.integrationApi.copyFailed);
    }
  }

  @override
  void dispose() {
    _uploadSourceLease?.release();
    _uploadSourceLease = null;
    _epoch++;
    _token.clear();
    _token.dispose();
    _search.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Translations.of(context).apiExplorer;
    final uploadText = _uploadText;
    final managementText = _managementText;
    final locale = TranslationProvider.of(context).locale;
    final lang = switch (locale) {
      AppLocale.zhCn => 'zh-CN',
      AppLocale.zhTw => 'zh-TW',
      AppLocale.zhHk => 'zh-HK',
      _ => 'en',
    };
    final asset = 'assets/api_docs/integration-openapi-$lang.json';
    if (_asset != asset && !_blocked) unawaited(_load(asset));
    final server = context.ref.watch(serverProvider);
    final catalog = _catalog;
    final matches = catalog?.operations.where((op) => (_group == 'all' || op.group == _group) && op.matches(_query)).toList() ?? [];
    final selected = catalog?.operations.where((op) => op.id == _selected).firstOrNull;
    final base = Uri(scheme: server?.https == true ? 'https' : 'http', host: '127.0.0.1', port: server?.port ?? 53317);
    final examples = selected?.examples(base, _values) ?? {};
    return Scaffold(
      appBar: AppBar(
        title: Text(text.title),
        actions: [
          ApiHistoryControlButton(
            language: lang,
            enabled: server != null && !_blocked,
            onBusy: (value) {
              if (mounted) setState(() => _exportBusy = value);
            },
            onRefreshed: (page) {
              if (mounted && _selected == 'listRequests') {
                setState(() => _result = {'status': 200, 'body': jsonEncode(page), 'binary': false, 'truncated': false});
              }
            },
            call: ((int expectedGeneration, String token) => (String operation, Map<String, Object>? body) async {
              final raw = await context.ref
                  .notifier(serverProvider)
                  .integrationApiRequest(
                    expectedGeneration: expectedGeneration,
                    request: jsonEncode({
                      'operation': operation,
                      'parameters': operation == 'listRequests' ? {'after': '0', 'limit': '100'} : <String, String>{},
                      'token': token,
                      'head': false,
                      'body': ?body,
                    }),
                  );
              final envelope = jsonDecode(raw) as Map<String, dynamic>;
              if (envelope['status'] != 200 || envelope['truncated'] == true || envelope['binary'] == true) {
                throw StateError('History request failed');
              }
              return jsonDecode(envelope['body'] as String) as Map<String, dynamic>;
            })(context.ref.notifier(serverProvider).generation, _token.text.trim()),
          ),
          ApiHistoryExportButton(
            language: lang,
            enabled: server != null && !_blocked,
            load: _loadHistory,
            onBusy: (value) {
              if (mounted) setState(() => _exportBusy = value);
            },
          ),
          IconButton(
            tooltip: t.integrationApi.documentation,
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ApiDocumentationPage())),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: catalog == null
              ? Center(
                  child: _loadFailed
                      ? TextButton(onPressed: () => _load(asset), child: Text(t.changelogPage.retry))
                      : const CircularProgressIndicator(),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(text.hint),
                    if (![AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk].contains(locale)) Text(t.integrationApi.fallback),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        StatusTag(label: server == null ? t.integrationApi.off : base.toString()),
                        StatusTag(
                          label: selected?.isUpload == true
                              ? uploadText.operation
                              : selected?.isManagement == true
                              ? managementText.operation
                              : selected?.isKeyMutation == true
                              ? ApiKeyStrings(locale.languageTag).operation
                              : selected?.isNativeTaskMutation == true
                              ? _transferText.nativeOperation
                              : selected?.isHostMutation == true
                              ? _transferText.hostOperation
                              : selected?.isTransferMutation == true
                              ? _transferText.operation
                              : text.readOnly,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('api-search'),
                      controller: _search,
                      onChanged: (s) => setState(() => _query = s),
                      decoration: InputDecoration(labelText: text.search, prefixIcon: const Icon(Icons.search)),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final entry in {
                          'all': text.all,
                          'service': text.service,
                          'workspaces': text.workspaces,
                          'files': text.files,
                          'history': text.history,
                          if (catalog.operations.any((op) => op.isTransfer)) 'transfers': _transferText.group,
                        }.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: _group == entry.key,
                            onSelected: _blocked ? null : (_) => setState(() => _group = entry.key),
                          ),
                      ],
                    ),
                    if (matches.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(text.noResults)),
                    for (final op in matches)
                      ListTile(
                        key: ValueKey('api-operation-${op.id}'),
                        dense: true,
                        selected: _selected == op.id,
                        title: Text('${op.method} ${op.path}'),
                        subtitle: Text(op.summary),
                        onTap: _blocked ? null : () => _select(op),
                      ),
                    if (selected != null) ...[
                      const Divider(),
                      Text(selected.summary, style: Theme.of(context).textTheme.titleLarge),
                      SelectableText('${selected.method} ${selected.path}'),
                      if (selected.description.isNotEmpty) Text(selected.description),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('api-console-token'),
                        controller: _token,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        enabled: !_blocked,
                        maxLength: 512,
                        decoration: InputDecoration(
                          labelText: text.token,
                          helperText: text.tokenHint,
                          helperMaxLines: 4,
                          suffixIcon: IconButton(onPressed: _blocked ? null : _token.clear, icon: const Icon(Icons.clear), tooltip: text.clear),
                        ),
                      ),
                      if (selected.isKeys) Text(ApiKeyStrings(locale.languageTag).hint),
                      if (selected.isManagement) Text(managementText.hint),
                      if (selected.isTransfer) Text(selected.isWorkspaceSend ? _transferText.action(selected.id) : _transferText.hint),
                      if (selected.isNativeTask) Text(_transferText.action(selected.id)),
                      for (final p in selected.inputParameters.where(
                        (p) =>
                            (!selected.isUpload || p.name != 'directory') &&
                            (!selected.isManagement || _values['action'] == 'update' || !['name', 'visible', 'allowUpload'].contains(p.name)),
                      ))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: selected.isManagement && ['action', 'visible', 'allowUpload'].contains(p.name)
                              ? _managementChoice(p)
                              : TextField(
                                  key: ValueKey('api-param-${p.name}'),
                                  controller: _fields.putIfAbsent(p.name, () => TextEditingController(text: selected.defaults()[p.name] ?? '')),
                                  enabled: !_blocked,
                                  maxLength: p.inputLimit == 0 ? null : p.inputLimit,
                                  onChanged: (_) => setState(() => _error = null),
                                  decoration: InputDecoration(
                                    labelText: selected.isManagement && p.name == 'name'
                                        ? managementText.name
                                        : '${p.name}${p.required ? ' *' : ''} · ${p.location}',
                                    helperText: '${p.description}\n${jsonEncode(p.schema)}',
                                    helperMaxLines: 4,
                                    counterText: '',
                                  ),
                                ),
                        ),
                      if (selected.bodyFields(_values).isNotEmpty) ...[
                        Text(
                          selected.isKeys
                              ? ApiKeyStrings(locale.languageTag).hint
                              : selected.isHost || selected.isNativeTask
                              ? _transferText.action(selected.id)
                              : selected.isTransfer
                              ? _transferText.requestHint
                              : _sourceText.bodyHint,
                        ),
                        if (selected.hasRequestId)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const ValueKey('api-transfer-new-request'),
                              onPressed: _blocked ? null : _newTransferRequest,
                              icon: const Icon(Icons.add),
                              label: Text(_transferText.newRequest),
                            ),
                          ),
                        const SizedBox(height: 12),
                        for (final field in selected.bodyFields(_values))
                          if (field == 'clear')
                            SwitchListTile.adaptive(
                              key: const ValueKey('api-body-clear'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(_sourceText.clear),
                              value: _values['body.clear'] == 'true',
                              onChanged: _blocked
                                  ? null
                                  : (value) => setState(() {
                                      _fields.putIfAbsent('body.clear', () => TextEditingController()).text = value ? 'true' : '';
                                      if (value) _fields['body.password']?.clear();
                                    }),
                            )
                          else if (field == 'sourceMode')
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: DropdownButtonFormField<String>(
                                key: const ValueKey('api-body-sourceMode'),
                                initialValue: _values['body.sourceMode'] ?? '',
                                isExpanded: true,
                                decoration: InputDecoration(labelText: _transferText.field(field)),
                                items: [
                                  DropdownMenuItem(value: '', child: Text(_transferText.filesystemSource)),
                                  DropdownMenuItem(value: 'documentSnapshot', child: Text(_transferText.documentSource)),
                                ],
                                onChanged: _blocked
                                    ? null
                                    : (value) => setState(() {
                                        _fields.putIfAbsent('body.sourceMode', TextEditingController.new).text = value ?? '';
                                        _error = null;
                                      }),
                              ),
                            )
                          else if (['visible', 'allowUpload'].contains(field))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('api-body-$field'),
                                initialValue: _values['body.$field']?.isNotEmpty == true ? _values['body.$field'] : '',
                                decoration: InputDecoration(labelText: field == 'visible' ? managementText.visible : managementText.allowUpload),
                                items: [
                                  DropdownMenuItem(value: '', child: Text(managementText.unchanged)),
                                  DropdownMenuItem(value: 'true', child: Text(managementText.yes)),
                                  DropdownMenuItem(value: 'false', child: Text(managementText.no)),
                                ],
                                onChanged: _blocked
                                    ? null
                                    : (value) => setState(() => _fields.putIfAbsent('body.$field', () => TextEditingController()).text = value ?? ''),
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: TextField(
                                key: ValueKey('api-body-$field'),
                                controller: _fields.putIfAbsent('body.$field', () => TextEditingController()),
                                enabled: !_blocked && (field != 'password' || _values['body.clear'] != 'true'),
                                obscureText: field == 'password',
                                enableSuggestions: field != 'password',
                                autocorrect: false,
                                minLines: ['files', 'ids'].contains(field) ? 3 : 1,
                                maxLines: ['files', 'ids'].contains(field) ? 6 : 1,
                                maxLength: field == 'ids'
                                    ? 2 * 1024 * 1024
                                    : field == 'path'
                                    ? 4096
                                    : field == 'files'
                                    ? 65536
                                    : selected.isKeys && ['scopes', 'workspaces'].contains(field)
                                    ? 4096
                                    : field == 'password'
                                    ? 128
                                    : field == 'slug'
                                    ? 48
                                    : field == 'sourceId'
                                    ? 36
                                    : 120,
                                onChanged: (_) => setState(() => _error = null),
                                decoration: InputDecoration(
                                  labelText: selected.isKeys
                                      ? ApiKeyStrings(locale.languageTag).field(field)
                                      : selected.isTransfer ||
                                            selected.isHost ||
                                            selected.isNativeTask ||
                                            selected.isPreviewLease ||
                                            selected.isArchiveSelection
                                      ? _transferText.field(field)
                                      : switch (field) {
                                          'sourceId' => _sourceText.sourceId,
                                          'slug' => _sourceText.slug,
                                          'password' => _sourceText.password,
                                          _ => managementText.name,
                                        },
                                  counterText: '',
                                ),
                              ),
                            ),
                      ],
                      if (selected.isUpload) ...[
                        SwitchListTile.adaptive(
                          key: const ValueKey('api-upload-empty-directory'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(uploadText.empty),
                          value: _values['directory'] == 'true',
                          onChanged: _blocked
                              ? null
                              : (value) => setState(() {
                                  _fields.putIfAbsent('directory', TextEditingController.new).text = value ? 'true' : 'false';
                                }),
                        ),
                        if (_values['directory'] != 'true') ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonalIcon(
                              key: const ValueKey('api-upload-pick'),
                              onPressed: _blocked ? null : _pickUpload,
                              icon: const Icon(Icons.attach_file),
                              label: Text(_uploadSource == null ? uploadText.choose : uploadText.replace),
                            ),
                          ),
                          if (_uploadSource case final source?) Text('${source.name} · ${source.size} B', key: const ValueKey('api-upload-source')),
                          Text(uploadText.sourceHint, style: Theme.of(context).textTheme.bodySmall),
                        ],
                        const SizedBox(height: 12),
                      ],
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('api-execute'),
                            onPressed: _blocked || server == null ? null : () => _execute(selected),
                            icon: _busy
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.play_arrow),
                            label: Text(_busy ? text.running : text.execute),
                          ),
                          TextButton(onPressed: _blocked ? null : () => _select(selected), child: Text(text.reset)),
                        ],
                      ),
                      if (_error != null)
                        Text(
                          _error!,
                          key: const ValueKey('api-console-error'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      if (_result case final result?) ...[
                        if (selected.isManagement) Text(managementText.review, key: const ValueKey('api-management-result-guidance')),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            StatusTag(label: 'HTTP ${result['status']}'),
                            if (result['elapsedMs'] != null) StatusTag(label: '${result['elapsedMs']} ms'),
                            if (result['bytes'] != null) StatusTag(label: '${result['bytes']} B'),
                          ],
                        ),
                        if (result['truncated'] == true) Text(text.truncated),
                        if (result['binary'] == true) Text(text.binary),
                        _TextPanel(
                          title: text.headers,
                          data: const JsonEncoder.withIndent('  ').convert(result['headers'] ?? <String, String>{}),
                          onCopy: _copy,
                        ),
                        _TextPanel(title: text.response, data: result['body'] as String, onCopy: _copy),
                      ],
                      ExpansionTile(
                        title: Text(text.examples),
                        children: [for (final example in examples.entries) _TextPanel(title: example.key, data: example.value, onCopy: _copy)],
                      ),
                      ExpansionTile(
                        title: Text(text.responses),
                        children: [
                          _TextPanel(title: text.responses, data: const JsonEncoder.withIndent('  ').convert(selected.responses), onCopy: _copy),
                        ],
                      ),
                      ExpansionTile(
                        title: Text(text.schemas),
                        children: [
                          for (final entry in catalog.schemas.entries)
                            ExpansionTile(
                              title: Text(entry.key),
                              children: [_TextPanel(title: entry.key, data: const JsonEncoder.withIndent('  ').convert(entry.value), onCopy: _copy)],
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _TextPanel extends StatelessWidget {
  final String title, data;
  final Future<void> Function(String) onCopy;
  const _TextPanel({required this.title, required this.data, required this.onCopy});
  @override
  Widget build(BuildContext context) {
    final chunks = apiDisplayChunks(data);
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title)),
                IconButton(icon: const Icon(Icons.copy, size: 18), tooltip: t.integrationApi.copy, onPressed: () => onCopy(data)),
              ],
            ),
            SizedBox(
              height: (chunks.length * 70.0).clamp(70, 280),
              child: ListView.builder(
                itemCount: chunks.length,
                itemBuilder: (context, index) => SelectableText(chunks[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
