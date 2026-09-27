import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/web/web_download_file.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';

final webReplacementPickerProvider = Provider<Future<List<CrossFile>> Function(BuildContext)>(
  (ref) => (context) async {
    // Do not use AddFileDialog here: its send-selection flow pops back to the
    // root and would dismiss this manager before replacement confirmation.
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final files = await android_channel.pickFilesAndroid();
        return files == null ? [] : await Future.wait(files.map(CrossFileConverters.convertFileInfo));
      }
      final file = await openFile();
      return file == null ? [] : [await CrossFileConverters.convertXFile(file)];
    } on PlatformException catch (error) {
      if (error.code == 'CANCELED') return [];
      rethrow;
    }
  },
);

/// One temporary share only. Page navigation never owns its service lifetime.
class WebSharedFilesPage extends StatefulWidget {
  final int generation;
  const WebSharedFilesPage({required this.generation, super.key});
  @override
  State<WebSharedFilesPage> createState() => _WebSharedFilesPageState();
}

class _WebSharedFilesPageState extends State<WebSharedFilesPage> {
  String _query = '';
  int _page = 0;
  bool _busy = false;
  bool _applying = false;

  Future<void> _change(WebDownloadFile file, bool replace) async {
    if (_busy) return;
    setState(() => _busy = true);
    final cacheLease = await context.ref.read(sourceCacheLeaseProvider).acquire();
    try {
      if (!mounted) return;
      final server = context.ref.notifier(serverProvider);
      final picked = replace ? await context.ref.read(webReplacementPickerProvider)(context) : <CrossFile>[];
      if (!mounted || replace && picked.isEmpty) return;
      if (replace && picked.length != 1) {
        context.showSnackBar(t.sharedFileManagement.selectOne);
        return;
      }
      if (server.generation != widget.generation || server.state?.webDownloadState?.files[file.file.id] != file) {
        context.showSnackBar(t.sharedFileManagement.changed);
        return;
      }
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(replace ? t.sharedFileManagement.replace : t.sharedFileManagement.withdraw),
          content: SingleChildScrollView(
            child: Text('${file.file.fileName}${replace ? '\n→ ${picked.single.name}' : ''}\n\n${t.sharedFileManagement.confirmBody}'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
            FilledButton(key: const ValueKey('confirm-file-change'), onPressed: () => Navigator.pop(context, true), child: Text(t.general.confirm)),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      setState(() => _applying = true);
      final applied = await server.patchWebFiles(expectedGeneration: widget.generation, removeFileIds: [file.file.id], replacements: picked);
      if (mounted) context.showSnackBar(applied ? t.sharedFileManagement.applied : t.sharedFileManagement.changed);
    } catch (_) {
      if (mounted) context.showSnackBar(t.sharedFileManagement.failed);
    } finally {
      cacheLease.release();
      if (mounted) {
        setState(() {
          _busy = false;
          _applying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Translations.of(context).sharedFileManagement;
    final source = context.ref.watch(
      serverProvider.select(
        (server) => (
          server?.webDownloadState?.files,
          server?.web?.pin,
          server?.https,
          server?.web is WebShareDownload && (server!.web! as WebShareDownload).duplex,
        ),
      ),
    );
    final current = source.$4 && context.ref.notifier(serverProvider).generation == widget.generation;
    final query = _query.toLowerCase();
    final filtered = (source.$1?.values ?? <WebDownloadFile>[]).where((entry) => entry.file.fileName.toLowerCase().contains(query)).toList();
    final pages = ((filtered.length + 49) ~/ 50).clamp(1, 1000000);
    final page = _page.clamp(0, pages - 1);
    final shown = filtered.skip(page * 50).take(50).toList();
    return Scaffold(
      appBar: AppBar(title: Text(text.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(text.hint),
                if (!current) Text(text.changed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('shared-file-search'),
                  onChanged: (value) => setState(() {
                    _query = value;
                    _page = 0;
                  }),
                  decoration: InputDecoration(labelText: text.search, prefixIcon: const Icon(Icons.search)),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusTag(label: '${filtered.length}'),
                    IconButton(
                      key: const ValueKey('shared-files-previous'),
                      tooltip: text.previous,
                      onPressed: page > 0 && !_busy ? () => setState(() => _page = page - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${page + 1} / $pages'),
                    IconButton(
                      key: const ValueKey('shared-files-next'),
                      tooltip: text.next,
                      onPressed: page < pages - 1 && !_busy ? () => setState(() => _page = page + 1) : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    if (_applying) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                Expanded(
                  child: shown.isEmpty
                      ? Center(child: Text(text.empty))
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (context, index) {
                            final entry = shown[index];
                            final title = Tooltip(
                              message: entry.file.fileName,
                              child: Text(entry.file.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                            );
                            final size = Text(entry.file.size.asReadableFileSize);
                            final actions = [
                              IconButton(
                                key: ValueKey('replace-${entry.file.id}'),
                                tooltip: text.replace,
                                onPressed: current && !_busy ? () => _change(entry, true) : null,
                                icon: const Icon(Icons.swap_horiz),
                              ),
                              IconButton(
                                key: ValueKey('withdraw-${entry.file.id}'),
                                tooltip: text.withdraw,
                                onPressed: current && !_busy ? () => _change(entry, false) : null,
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                            ];
                            return Card.filled(
                              key: ValueKey('shared-file-${entry.file.id}'),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  if (constraints.maxWidth < 480 || MediaQuery.textScalerOf(context).scale(1) > 1.4) {
                                    return Padding(
                                      padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          title,
                                          Row(
                                            children: [
                                              Expanded(child: size),
                                              ...actions,
                                            ],
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return ListTile(
                                    title: title,
                                    subtitle: size,
                                    trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
