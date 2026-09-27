import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

/// A read-only availability probe. Document trees remain content URIs and never
/// become filesystem paths. Serving uses the listener-owned isolate bridge.
class AndroidWorkspaceDocuments {
  final MethodChannel channel;
  final Duration timeout;
  const AndroidWorkspaceDocuments({
    this.channel = const MethodChannel('org.localsend.localsend_app/localsend'),
    this.timeout = const Duration(milliseconds: 2500),
  });

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String> probe(String tree) async {
    await _probe(tree, requireWritable: false);
    return tree;
  }

  /// Checks existing persisted authority; never opens a permission picker or
  /// creates a document on behalf of a remote management request.
  Future<void> requireWritable(String tree) => _probe(tree, requireWritable: true);

  Future<void> _probe(String tree, {required bool requireWritable}) async {
    if (!supported) throw UnsupportedError('Android document workspaces unavailable');
    final uri = Uri.tryParse(tree);
    if (uri == null ||
        uri.scheme != 'content' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.pathSegments.contains('tree') ||
        tree.length > 32768 ||
        tree.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('Invalid document tree');
    }
    final requestId = const Uuid().v4();
    final request = {
      'version': 1,
      'requestId': requestId,
      'owner': const Uuid().v4(),
      'workspaceId': const Uuid().v4(),
      'generation': 0,
      'tree': tree,
      'op': 'probe',
    };
    try {
      final response = await channel.invokeMapMethod<String, Object?>('workspaceDocuments', {'request': jsonEncode(request)}).timeout(timeout);
      if (response == null || response['fd'] != null || response['payload'] is! String || (response['payload'] as String).length > 4096) {
        throw const FormatException('Invalid document probe response');
      }
      final payload = jsonDecode(response['payload'] as String);
      if (payload is! Map || payload['version'] != 1 || payload['readable'] != true) {
        throw const FormatException('Document root is not readable');
      }
      if (requireWritable && payload['writable'] != true) {
        throw PlatformException(code: 'permission', message: 'Document tree has no writable grant or create capability');
      }
    } on TimeoutException {
      // Revoke this pending operation, not the tree grant used by another
      // workspace or receive destination. A blocked provider retains its slot.
      unawaited(
        channel
            .invokeMethod<void>('workspaceDocuments', {
              'request': jsonEncode({'version': 1, 'op': 'cancel', 'requestId': requestId}),
            })
            .catchError((Object _) {}),
      );
      rethrow;
    }
  }
}
