import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/apk_picker_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/android_folder_strings.dart';
import 'package:localsend_app/util/determine_image_type.dart';
import 'package:localsend_app/util/image_converter.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/ui/asset_picker_translated_text_delegate.dart';
import 'package:localsend_app/widget/album_batch_picker.dart';
import 'package:localsend_app/widget/dialogs/loading_dialog.dart';
import 'package:localsend_app/widget/dialogs/message_input_dialog.dart';
import 'package:localsend_app/widget/dialogs/no_permission_dialog.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:logging/logging.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uri_content/uri_content.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

final _logger = Logger('FilePickerHelper');
final _uriContent = UriContent();

enum FilePickerOption {
  file(Icons.description),
  folder(Icons.folder),
  media(Icons.image),
  text(Icons.subject),
  app(Icons.apps),
  clipboard(Icons.paste)
  ;

  const FilePickerOption(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case FilePickerOption.file:
        return t.sendTab.picker.file;
      case FilePickerOption.folder:
        return t.sendTab.picker.folder;
      case FilePickerOption.media:
        return t.sendTab.picker.media;
      case FilePickerOption.text:
        return t.sendTab.picker.text;
      case FilePickerOption.app:
        return t.sendTab.picker.app;
      case FilePickerOption.clipboard:
        return t.sendTab.picker.clipboard;
    }
  }

  /// Returns the options for the current platform.
  static List<FilePickerOption> getOptionsForPlatform() {
    if (checkPlatform([TargetPlatform.iOS])) {
      // On iOS, picking from media is most common.
      // The file app is very limited.
      return [
        FilePickerOption.media,
        FilePickerOption.text,
        FilePickerOption.clipboard,
        FilePickerOption.file,
        FilePickerOption.folder,
      ];
    } else if (checkPlatform([TargetPlatform.android])) {
      // On android, the file app is most powerful.
      // It actually also allows to pick media files.
      return [
        FilePickerOption.file,
        FilePickerOption.media,
        FilePickerOption.clipboard,
        FilePickerOption.text,
        FilePickerOption.folder,
        FilePickerOption.app,
      ];
    } else {
      // Desktop media uses the filesystem's multi-selection dialog.
      return [
        FilePickerOption.file,
        FilePickerOption.media,
        FilePickerOption.folder,
        FilePickerOption.text,
        FilePickerOption.clipboard,
      ];
    }
  }
}

class PickFileAction extends AsyncGlobalAction {
  final FilePickerOption option;
  final BuildContext context;

  PickFileAction({
    required this.option,
    required this.context,
  });

  @override
  Future<void> reduce() async {
    await ref.read(sourceCacheLeaseProvider).withLease(() async {
      if (!context.mounted) return;
      switch (option) {
        case FilePickerOption.file:
          await _pickFiles(context, ref);
          break;
        case FilePickerOption.folder:
          // ignore: use_build_context_synchronously
          await _pickFolder(context, ref);
          break;
        case FilePickerOption.media:
          // ignore: use_build_context_synchronously
          await _pickMedia(context, ref);
          break;
        case FilePickerOption.text:
          // ignore: use_build_context_synchronously
          await _pickText(context, ref);
          break;
        case FilePickerOption.clipboard:
          // ignore: use_build_context_synchronously
          await _pickClipboard(context, ref);
          break;
        case FilePickerOption.app:
          // ignore: use_build_context_synchronously
          await _pickApp(context);
          break;
      }
    });
  }

  @override
  String toString() {
    return 'PickAction(option: $option)';
  }
}

Future<void> _pickFiles(BuildContext context, Ref ref) async {
  if (checkPlatform([TargetPlatform.android])) {
    // On android, the files are copied to the cache which takes some time.
    // ignore: unawaited_futures
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoadingDialog(),
    );
  }
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final result = await android_channel.pickFilesAndroid();
      if (result != null) {
        await ref
            .redux(selectedSendingFilesProvider)
            .dispatchAsync(
              AddFilesAction(
                files: result,
                converter: CrossFileConverters.convertFileInfo,
              ),
            );
      }
    } else {
      final result = await openFiles();
      await ref
          .redux(selectedSendingFilesProvider)
          .dispatchAsync(
            AddFilesAction(
              files: result,
              converter: CrossFileConverters.convertXFile,
            ),
          );
    }
  } catch (e) {
    if (e is PlatformException && e.code == 'CANCELED') {
      // User canceled the file picker
      _logger.info('User canceled file picker');
      return;
    }

    // ignore: use_build_context_synchronously
    await showDialog(context: context, builder: (_) => const NoPermissionDialog());
    _logger.warning('Failed to pick files', e);
  } finally {
    // ignore: use_build_context_synchronously
    Routerino.context.popUntilRoot(); // remove loading dialog
  }
}

Future<void> _pickFolder(BuildContext context, Ref ref) async {
  if (checkPlatform([TargetPlatform.android])) {
    try {
      await Permission.storage.request();
    } catch (e) {
      _logger.warning('Failed to request storage permission', e);
    }
  }

  if (!context.mounted) {
    return;
  }

  String? folderFeedback;
  final folderCopy = AndroidFolderStrings(Translations.of(context).$meta.locale);
  // ignore: unawaited_futures
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const LoadingDialog(),
  );
  await sleepAsync(200); // Wait for the dialog to be shown
  try {
    if (defaultTargetPlatform == TargetPlatform.android && (ref.read(deviceInfoProvider).androidSdkInt ?? 0) >= android_channel.contentUriMinSdk) {
      // The native provider traversal supplies paths independently of opaque IDs.
      final result = await android_channel.pickDirectoryAndroid();
      if (result != null) {
        await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddAndroidDirectoryAction(result));
        if (result.emptyDirectories > 0) folderFeedback = folderCopy.empty(result.emptyDirectories);
      }
    } else {
      final directoryPath = await pickDirectoryPath();
      if (directoryPath != null) {
        final action = AddDirectoryAction(directoryPath);
        await ref.redux(selectedSendingFilesProvider).dispatchAsync(action);
        if (action.emptyDirectories > 0) folderFeedback = folderCopy.empty(action.emptyDirectories);
      }
    }
  } catch (e) {
    if (e is PlatformException && {'CANCELED', 'cancelled'}.contains(e.code)) {
      // User canceled the file picker
      _logger.info('User canceled file picker');
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      folderFeedback = folderCopy.error(e is PlatformException ? e.code : 'unavailable');
    } else {
      _logger.warning('Failed to pick directory', e);
      if (context.mounted) await showDialog(context: context, builder: (_) => const NoPermissionDialog());
    }
  } finally {
    // ignore: use_build_context_synchronously
    Routerino.context.popUntilRoot(); // remove loading dialog
  }
  if (context.mounted && folderFeedback != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(folderFeedback)));
  }
}

/// Desktop media is an ordinary filesystem multi-picker, not an OS album API.
const desktopMediaFileTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'Photos and videos',
    extensions: [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'avif',
      'bmp',
      'tif',
      'tiff',
      'mp4',
      'mov',
      'm4v',
      'mkv',
      'avi',
      'webm',
      'mpeg',
      'mpg',
    ],
    uniformTypeIdentifiers: ['public.image', 'public.movie'],
  ),
];

Future<void> _pickMedia(BuildContext context, Ref ref) async {
  if (!checkPlatformWithGallery()) {
    try {
      final files = await openFiles(acceptedTypeGroups: desktopMediaFileTypes);
      if (files.isNotEmpty) {
        await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddFilesAction(files: files, converter: CrossFileConverters.convertXFile));
      }
    } catch (error) {
      _logger.warning('Failed to pick media files', error);
      if (context.mounted) await showDialog(context: context, builder: (_) => const NoPermissionDialog());
    }
    return;
  }
  final oldBrightness = Theme.of(context).brightness;
  try {
    const permissionRequest = PermissionRequestOption(
      androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: true),
    );
    final permission = await AssetPicker.permissionCheck(requestOption: permissionRequest);
    if (!context.mounted) return;
    final provider = DefaultAssetPickerProvider(maxAssets: 999, pageSize: 80, requestType: RequestType.common);
    final delegate = AlbumBatchPickerDelegate(
      provider: provider,
      initialPermission: permission,
      textDelegate: const TranslatedAssetPickerTextDelegate(),
      pickerTheme: Theme.of(context),
    );
    final result = await Navigator.of(context, rootNavigator: true).push<List<AssetEntity>>(
      AssetPickerPageRoute<List<AssetEntity>>(
        builder: (_) => AssetPicker<AssetEntity, AssetPathEntity, AlbumBatchPickerDelegate>(
          permissionRequestOption: permissionRequest,
          builder: delegate,
        ),
      ),
    );
    if (result != null) {
      await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddFilesAction(files: result, converter: CrossFileConverters.convertAssetEntity));
    }
  } catch (error) {
    _logger.warning('Failed to pick album media', error);
    if (context.mounted) await showDialog(context: context, builder: (_) => const NoPermissionDialog());
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await sleepAsync(500);
      if (context.mounted) await updateSystemOverlayStyleWithBrightness(oldBrightness);
    });
  }
}

Future<void> _pickText(BuildContext context, Ref ref) async {
  final result = await showDialog<String>(context: context, builder: (_) => const MessageInputDialog());
  if (result != null) {
    ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: result));
  }
}

Future<void> _pickClipboard(BuildContext context, Ref ref) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  if (data?.text != null) {
    ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: data!.text!));
    return;
  }

  final image = await Pasteboard.image;
  if (image != null) {
    // Adding temporary variable because Dart analyzer somehow doesn't properly downcast Uint8List? to Uint8List
    Uint8List currImage = image;
    String imageType = determineImageType(image);

    // On Windows, Pasteboard read image from clipboard as BMP which is large and inefficient. Attempt to convert to PNG
    if (imageType == 'bmp') {
      try {
        final pngImage = await convertBmpToPng(image);
        currImage = pngImage;
        imageType = 'png';
      } catch (e) {
        // Fail to convert to png, proceed with existing bmp
      }
    }

    final now = DateTime.now();
    final fileName =
        'clipboard_${now.year}-${now.month.twoDigitString}-${now.day.twoDigitString}_${now.hour.twoDigitString}-${now.minute.twoDigitString}.$imageType';
    ref
        .redux(selectedSendingFilesProvider)
        .dispatch(
          AddBinaryAction(
            bytes: currImage,
            fileType: FileType.image,
            fileName: fileName,
          ),
        );
    return;
  }

  final List<String> files = await Pasteboard.files();
  if (files.isNotEmpty) {
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction(
            files: files.map((e) => XFile(e)).toList(),
            converter: (file) async {
              if (!file.path.startsWith('content://')) {
                return CrossFileConverters.convertXFile(file);
              }
              // handle content uri
              return CrossFile(
                name: file.name,
                fileType: file.name.guessFileType(),
                size: await _uriContent.getContentLength(Uri.parse(file.path)) ?? -1,
                path: file.path,
                thumbnail: null,
                asset: null,
                bytes: null,
                lastModified: null,
                lastAccessed: null,
              );
            },
          ),
        );
    return;
  }

  if (!context.mounted) {
    return;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(t.general.noItemInClipboard),
    ),
  );
}

Future<void> _pickApp(BuildContext context) async {
  // Currently, only Android APK
  await context.push(() => const ApkPickerPage());
}

extension on int {
  String get twoDigitString => toString().padLeft(2, '0');
}
