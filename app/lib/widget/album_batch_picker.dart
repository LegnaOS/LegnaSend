import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/album_batch_strings.dart';
import 'package:localsend_app/util/native/album_batch_selection.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// Keeps the package's real grid, previews, limited-access UI and confirmation.
class AlbumBatchPickerDelegate extends DefaultAssetPickerBuilderDelegate<DefaultAssetPickerProvider> {
  AlbumBatchPickerDelegate({required super.provider, required super.initialPermission, required super.textDelegate, required super.pickerTheme});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(child: super.build(context)),
      Material(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: AlbumBatchBar(provider: provider),
        ),
      ),
    ],
  );
}

class AlbumBatchBar extends StatefulWidget {
  final DefaultAssetPickerProvider provider;

  /// Metadata-only injection for provider-independent widget regression tests.
  final Future<List<AssetEntity>> Function(AssetPathEntity path, int page, int size)? loadPage;
  const AlbumBatchBar({super.key, required this.provider, this.loadPage});

  @override
  State<AlbumBatchBar> createState() => _AlbumBatchBarState();
}

class _AlbumBatchBarState extends State<AlbumBatchBar> {
  bool _busy = false;
  bool _cancelled = false;

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _select() async {
    final path = widget.provider.currentPath?.path;
    if (_busy || path == null) return;
    setState(() {
      _busy = true;
      _cancelled = false;
    });
    final copy = AlbumBatchStrings(Translations.of(context).$meta.locale);
    final progress = ValueNotifier<int>(widget.provider.selectedAssets.length);
    // The modal prevents changing albums, individual selections or confirmation
    // while a metadata snapshot is being built. Back/Cancel discard that snapshot.
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _cancelled = true;
        },
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, count, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [const LinearProgressIndicator(), const SizedBox(height: 20), Text(copy.progress(count))],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _cancelled = true;
                Navigator.of(dialogContext).pop();
              },
              child: Text(copy.cancel),
            ),
          ],
        ),
      ),
    );
    var dialogClosed = false;
    final dialogDone = dialog.then((_) {
      dialogClosed = true;
      _cancelled = true;
    });
    AlbumBatchResult<AssetEntity>? result;
    var failed = false;
    try {
      result = await collectAlbumBatch<AssetEntity>(
        existing: widget.provider.selectedAssets,
        loadPage: (page, size) => widget.loadPage?.call(path, page, size) ?? path.getAssetListPaged(page: page, size: size),
        id: (asset) => asset.id,
        cancelled: () => _cancelled || !mounted || widget.provider.currentPath?.path.id != path.id,
        onProgress: (count) => progress.value = count,
      );
    } on AlbumBatchCancelled {
      // Keep the user's previous selection intact.
    } catch (_) {
      failed = true;
    }
    final apply = !_cancelled && mounted && widget.provider.currentPath?.path.id == path.id;
    if (!dialogClosed && mounted && !_cancelled) Navigator.of(context, rootNavigator: true).pop();
    await dialogDone;
    progress.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!apply) return;
    if (result != null) widget.provider.selectedAssets = result.selected;
    if (failed || (result?.limited ?? false)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(failed ? copy.failed : copy.limited)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AlbumBatchStrings(Translations.of(context).$meta.locale);
    return AnimatedBuilder(
      animation: widget.provider,
      builder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: _busy || widget.provider.currentPath == null ? null : _select,
              icon: const Icon(Icons.select_all),
              label: Text(copy.select),
            ),
            Text(copy.hint, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
