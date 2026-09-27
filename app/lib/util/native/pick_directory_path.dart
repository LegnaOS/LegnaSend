import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Opens a file picker to select a directory.
/// Returns null if the user cancels the selection.
Future<String?> pickDirectoryPath({bool requireWrite = false}) async {
  if (defaultTargetPlatform == TargetPlatform.android &&
      (RefenaScope.defaultRef.read(deviceRawInfoProvider).androidSdkInt ?? 0) >= android_channel.contentUriMinSdk) {
    return await android_channel.pickDirectoryPathAndroid(requireWrite: requireWrite);
  }

  if (checkPlatform([TargetPlatform.android, TargetPlatform.iOS])) {
    /// We need to use the file_picker package because file_selector does not expose the raw path.
    /// We need the raw path to properly manipulate the path to save new files, or
    /// to list files recursively.
    /// Also, on iOS, file_selector does not work with directories.
    return await FilePicker.getDirectoryPath();
  } else {
    return await file_selector.getDirectoryPath();
  }
}

/// A rejected/revoked destination never replaces the user's current setting.
Future<String?> pickReceiveDirectoryPath(BuildContext context, {Future<String?> Function()? pick}) async {
  try {
    final directory =
        await (pick ??
            () async {
              if (checkPlatform([TargetPlatform.iOS])) {
                final path = await const MethodChannel('legnasend/ios_receive').invokeMethod<String>('pick');
                if (path != null && (!path.startsWith('/') || path.contains('\u0000') || path.length > 32768)) {
                  throw const FormatException('Invalid authorized receive directory');
                }
                return path;
              }
              return pickDirectoryPath(requireWrite: true);
            })();
    return context.mounted ? directory : null;
  } catch (_) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => ErrorDialog(error: t.receivePage.destinationUnavailable),
      );
    }
    return null;
  }
}
