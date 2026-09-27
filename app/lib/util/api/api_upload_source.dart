import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android;

/// Picker metadata only: no file payload or native handle is retained by the UI.
class ApiUploadSource {
  final String name;
  final String path;
  final int size;
  const ApiUploadSource({required this.name, required this.path, required this.size});

  bool get isContentUri => path.startsWith('content://');
  Map<String, Object> get requestFields => {
    if (isContentUri) 'uploadUri': path else 'uploadPath': path,
    'uploadSize': size,
  };
}

Future<ApiUploadSource?> pickApiUploadSource() async {
  try {
    if (Platform.isAndroid) {
      final files = await android.pickFilesAndroid();
      if (files == null || files.isEmpty) return null;
      if (files.length != 1) throw const FormatException('Select one file');
      final file = files.single;
      if (file.size < 0) throw StateError('Unknown file size');
      return ApiUploadSource(name: file.name, path: file.uri, size: file.size);
    }
    final file = await openFile();
    if (file == null) return null;
    return ApiUploadSource(name: file.name, path: file.path, size: await file.length());
  } on PlatformException catch (error) {
    if (error.code == 'CANCELED' || error.code == 'CANCELLED') return null;
    rethrow;
  }
}
