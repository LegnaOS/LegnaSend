import 'package:flutter/services.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/localsend');

/// Opens [uri] for reading and returns an owned Linux file descriptor.
///
/// The descriptor stays open after this call and must be closed by the native
/// consumer it is passed to.
Future<int> getFileDescriptorAndroid({required String uri}) async {
  final fileDescriptor = await _methodChannel.invokeMethod<int>('getFileDescriptor', {
    'uri': uri,
  });
  if (fileDescriptor == null) {
    throw StateError('Android returned no file descriptor for $uri');
  }
  return fileDescriptor;
}

/// Revalidate the persisted writable tree grant and resolve real provider IDs.
/// No filename/path arithmetic is valid for opaque SAF document identifiers.
Future<String> resolveReceiveDirectoryAndroid({required String treeUri, required List<String> components}) async {
  final result = await _methodChannel.invokeMethod<String>('resolveReceiveDirectory', {
    'treeUri': treeUri,
    'components': components,
  });
  final uri = result == null ? null : Uri.tryParse(result);
  if (uri == null || uri.scheme != 'content' || uri.authority.isEmpty) {
    throw StateError('Android returned no destination document');
  }
  return result!;
}

class CreatedFileAndroid {
  /// The URI of the created document. Android may rename the file on collisions.
  final String uri;

  /// An owned writable Linux file descriptor. It stays open after this call and
  /// must be closed by the native consumer it is passed to.
  final int fileDescriptor;

  CreatedFileAndroid({required this.uri, required this.fileDescriptor});
}

/// Creates a new file inside a SAF directory (a tree or document URI)
/// and opens it for writing.
Future<CreatedFileAndroid> createFileAndroid({
  required String parentUri,
  required String fileName,
  required String mimeType,
}) async {
  final result = await _methodChannel.invokeMethod<Map>('createFile', {
    'parentUri': parentUri,
    'fileName': fileName,
    'mimeType': mimeType,
  });
  if (result == null) {
    throw StateError('Android could not create $fileName in $parentUri');
  }
  return CreatedFileAndroid(
    uri: result['uri'] as String,
    fileDescriptor: result['fd'] as int,
  );
}

/// Opens an existing document created by [createFileAndroid] for writing and
/// discards its current content.
///
/// The descriptor stays open after this call and must be closed by the native
/// consumer it is passed to.
Future<int> openFileForWritingAndroid({required String uri}) async {
  final fileDescriptor = await _methodChannel.invokeMethod<int>('openFileForWriting', {
    'uri': uri,
  });
  if (fileDescriptor == null) {
    throw StateError('Android returned no file descriptor for $uri');
  }
  return fileDescriptor;
}
