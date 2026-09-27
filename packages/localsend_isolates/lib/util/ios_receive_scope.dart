import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const _channel = MethodChannel('legnasend/ios_receive');
final _leasePattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// A native security scope AND coordinated accessor, not just a remembered path.
class IosReceiveScopeLease {
  final String leaseId;
  final String path;
  final Future<void> Function(String) _release;
  Future<void>? _released;

  IosReceiveScopeLease({required this.leaseId, required this.path, Future<void> Function(String)? release})
    : _release = release ?? releaseIosReceiveScope;

  Future<void> release() => _released ??= Future.sync(() => _release(leaseId));
}

void _path(String path) {
  if (!p.posix.isAbsolute(path) || path.contains('\u0000')) throw ArgumentError('Expected an absolute iOS receive directory');
}

Future<IosReceiveScopeLease?> acquireIosReceiveScope(String path) => _acquireIosScope(path, 'acquire');

/// Maintenance never overlaps an active or waiting receiver on the same tree.
Future<IosReceiveScopeLease?> acquireIosReceiveMaintenanceScope(String path) => _acquireIosScope(path, 'acquireMaintenance');

/// Remembered external roots only; live authority must still be acquired.
Future<List<String>> listIosGrantedReceivePaths() async {
  final result = await _channel.invokeMethod<Object?>('listGrantedPaths');
  if (result is! List || result.length > 128) throw const FormatException('Invalid iOS receive roots');
  final roots = <String>{};
  for (final value in result) {
    if (value is! String) throw const FormatException('Invalid iOS receive root');
    _path(value);
    if (!roots.add(value)) throw const FormatException('Duplicate iOS receive root');
  }
  return List.unmodifiable(roots);
}

Future<IosReceiveScopeLease?> _acquireIosScope(String path, String method) async {
  _path(path);
  final result = await _channel.invokeMapMethod<String, dynamic>(method, {'path': path});
  // Only native sandbox classification may return null; never infer it from a prefix here.
  if (result == null) return null;
  final id = result['leaseId'];
  if (id is! String || !_leasePattern.hasMatch(id) || result['path'] != path) {
    if (id is String && _leasePattern.hasMatch(id)) await releaseIosReceiveScope(id);
    throw const FormatException('Receive directory scope did not match the approved path');
  }
  return IosReceiveScopeLease(leaseId: id, path: path);
}

Future<void> releaseIosReceiveScope(String leaseId) async {
  if (!_leasePattern.hasMatch(leaseId)) throw ArgumentError('Invalid iOS receive scope lease');
  await _channel.invokeMethod<void>('release', {'leaseId': leaseId});
}

/// A remembered-grant marker, not proof that provider authorization is still live.
Future<bool> isGrantedIosReceivePath(String path) async {
  _path(path);
  return await _channel.invokeMethod<bool>('isGrantedPath', {'path': path}) ?? false;
}
