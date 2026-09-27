import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/download_directory.dart';
import 'package:path_provider/path_provider.dart' as path;

Future<String> getDefaultDestinationDirectory() => resolveDefaultDownloadDirectory(
  platform: defaultTargetPlatform,
  systemDownloads: () async =>
      defaultTargetPlatform == TargetPlatform.android ? await getDownloadsDirectoryAndroid() : (await path.getDownloadsDirectory())?.path,
  applicationDocuments: () async => (await path.getApplicationDocumentsDirectory()).path,
  environment: Platform.environment,
);

Future<String> getCacheDirectory() async {
  final dir = await path.getTemporaryDirectory();
  await dir.create(recursive: true);
  return dir.path;
}
