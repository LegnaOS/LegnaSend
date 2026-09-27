import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:refena_flutter/refena_flutter.dart';

final iosWorkspaceGrantsProvider = Provider<IosWorkspaceGrants>((_) => const IosWorkspaceGrants());

class WorkspaceGrantLease {
  final String id;
  final Map<String, String> roots;
  const WorkspaceGrantLease(this.id, this.roots);
}

/// Shared Apple grant bridge. The historical channel/provider name stays stable.
/// Native bookmark bytes never enter a workspace URL, catalog or API response.
/// Existing plain macOS paths are not grants: they need explicit folder selection.
class IosWorkspaceGrants {
  final MethodChannel channel;
  const IosWorkspaceGrants({this.channel = const MethodChannel('legnasend/ios_workspace')});
  bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);
  static final _id = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
  static String _grant(Object? value) {
    if (value is! String || !_id.hasMatch(value)) throw const FormatException('Invalid workspace grant');
    return value;
  }

  static String _path(Object? value) {
    if (value is! String || !value.startsWith('/') || value.length > 32768 || value.contains('\u0000')) {
      throw const FormatException('Invalid workspace directory');
    }
    return value;
  }

  Future<WorkspaceSource?> pick() async {
    if (!supported) throw UnsupportedError('Apple directory authorization unavailable');
    final result = await channel.invokeMapMethod<String, Object?>('pick');
    if (result == null) return null;
    return WorkspaceSource(kind: WorkspaceSourceKind.appleBookmark, locator: _path(result['locator']), grantId: _grant(result['grantId']));
  }

  Future<String> probe(String id) async {
    if (!supported) throw UnsupportedError('Apple directory authorization unavailable');
    return _path(await channel.invokeMethod<Object?>('probe', {'grantId': _grant(id)}));
  }

  Future<WorkspaceGrantLease?> acquire(Iterable<String> ids, {WorkspaceGrantLease? retaining}) async {
    final unique = ids.toSet().toList(growable: false);
    if (unique.isEmpty) return retaining;
    if (!supported || unique.length > 128) throw UnsupportedError('Workspace grants unavailable');
    for (final id in unique) {
      _grant(id);
    }
    final result = await channel.invokeMapMethod<String, Object?>('acquire', {'grantIds': unique, if (retaining != null) 'leaseId': retaining.id});
    if (result == null || result['roots'] is! Map) throw const FormatException('Invalid workspace lease');
    final leaseId = _grant(result['leaseId']);
    try {
      if (retaining != null && retaining.id != leaseId) throw const FormatException('Workspace lease changed');
      final roots = (result['roots'] as Map).map((key, value) => MapEntry(_grant(key), _path(value)));
      if (roots.length > 128 || unique.any((id) => !roots.containsKey(id))) throw const FormatException('Incomplete workspace lease');
      return WorkspaceGrantLease(leaseId, Map.unmodifiable(roots));
    } catch (_) {
      // A malformed reply does not prove the native operation failed. Never
      // revoke a possibly serving retained scope based on a transport error.
      if (retaining == null) await channel.invokeMethod<void>('release', {'leaseId': leaseId});
      rethrow;
    }
  }

  Future<WorkspaceGrantLease?> retainOnly(WorkspaceGrantLease? lease, Iterable<String> ids) async {
    if (lease == null) return null;
    final keep = ids.toSet().toList(growable: false);
    if (keep.isEmpty) {
      await release(lease);
      return null;
    }
    if (keep.any((id) => !lease.roots.containsKey(id))) throw const FormatException('Unknown retained grant');
    await channel.invokeMethod<void>('retainOnly', {'leaseId': lease.id, 'grantIds': keep});
    return WorkspaceGrantLease(lease.id, Map.unmodifiable({for (final id in keep) id: lease.roots[id]!}));
  }

  Future<void> release(WorkspaceGrantLease? lease) async {
    if (lease != null) await channel.invokeMethod<void>('release', {'leaseId': _grant(lease.id)});
  }

  Future<void> adopt(String id) async {
    await channel.invokeMethod<void>('adopt', {'grantId': _grant(id)});
  }

  Future<void> prune(Iterable<String> keeping) async {
    if (!supported) return;
    final ids = keeping.toSet().toList(growable: false);
    for (final id in ids) {
      _grant(id);
    }
    await channel.invokeMethod<void>('prune', {'grantIds': ids});
  }

  Future<void> discard(String id) async {
    await channel.invokeMethod<void>('discard', {'grantId': _grant(id)});
  }
}
