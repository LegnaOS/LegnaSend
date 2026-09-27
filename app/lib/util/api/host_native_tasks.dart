import 'dart:convert';

import 'package:localsend_app/model/transfer_activity.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _id = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// A redacted projection of an actual native task, never a fabricated API job.
class HostNativeTask {
  final TransferActivity activity;
  final Object controlRevision;
  final int bytesPerSecond;
  final List<String> actions;
  const HostNativeTask({required this.activity, required this.controlRevision, required this.actions, this.bytesPerSecond = 0});
}

class _Identity {
  final String id = _uuid.v4();
  String version = _uuid.v4();
  Object revision;
  _Identity(this.revision);
}

/// Global access is deliberately separate from key-owned TransferManagement.
/// Control revisions exclude byte progress but include the actual session attempt
/// and local receive destination/selection. Claim completion is followed by CAS.
class HostNativeTasks {
  final int Function() readGeneration;
  final List<HostNativeTask> Function() readTasks;
  final Future<void> Function(HostNativeTask task, String action) control;
  final _identities = <String, _Identity>{};
  int? _generation;
  String _epoch = _uuid.v4();
  HostNativeTasks({required this.readGeneration, required this.readTasks, required this.control});

  List<HostNativeTask> _refresh() {
    final generation = readGeneration();
    if (_generation != generation) {
      _generation = generation;
      _epoch = _uuid.v4();
      _identities.clear();
    }
    final tasks = readTasks();
    final keys = tasks.take(512).map((t) => t.activity.key).toSet();
    _identities.removeWhere((key, _) => !keys.contains(key));
    for (final task in tasks.take(512)) {
      final identity = _identities.putIfAbsent(task.activity.key, () => _Identity(task.controlRevision));
      if (identity.revision != task.controlRevision) {
        identity.revision = task.controlRevision;
        identity.version = _uuid.v4();
      }
    }
    return tasks;
  }

  Map<String, Object> _view(HostNativeTask task) {
    final activity = task.activity;
    final identity = _identities[activity.key]!;
    return {
      'id': identity.id,
      'version': identity.version,
      'direction': activity.direction.name,
      'phase': activity.phase.name,
      'fileCount': activity.files.length,
      'totalBytes': activity.totalBytes,
      'transferredBytes': activity.transferredBytes.clamp(0, activity.totalBytes),
      'bytesPerSecond': activity.active ? task.bytesPerSecond.clamp(0, 0x1fffffffffffff) : 0,
      'actions': task.actions,
    };
  }

  // There is deliberately no cross-task asynchronous lock: accepting a receive
  // may await a mobile permission dialog. Other task reads/cancels must remain
  // available. The claim-return CAS and version consumption contain no await.
  Future<String> execute({required String request, required Future<bool> Function() claim}) async {
    String response(int status, Map<String, Object> body) => jsonEncode({'status': status, 'body': body});
    String fail(int status, String code) => response(status, {
      'error': {'code': code},
    });
    try {
      final value = jsonDecode(request) as Map<String, dynamic>;
      if (value['principal'] is! String ||
          value['workspaces'] is! List ||
          (value['workspaces'] as List).length != 1 ||
          value['workspaces'][0] != '*') {
        return fail(403, 'global_native_task_key_required');
      }
      var tasks = _refresh();
      if (value['operation'] == 'nativeTasks.list') {
        if (!await claim()) return fail(409, 'operation_expired');
        tasks = _refresh();
        return response(200, {'epoch': _epoch, 'tasks': tasks.take(512).map(_view).toList(), 'truncated': tasks.length > 512});
      }
      if (value['operation'] != 'nativeTasks.control') return fail(400, 'invalid_operation');
      final change = value['change'];
      if (change is! Map ||
          change.length != 3 ||
          !['epoch', 'version'].every((k) => change[k] is String && _id.hasMatch(change[k] as String)) ||
          !['cancel', 'accept', 'reject', 'remove'].contains(change['action']) ||
          value['taskId'] is! String ||
          !_id.hasMatch(value['taskId'] as String)) {
        return fail(400, 'invalid_body');
      }
      HostNativeTask? target() => tasks.take(512).where((t) => _identities[t.activity.key]?.id == value['taskId']).firstOrNull;
      bool matches(HostNativeTask? task) => task != null && change['epoch'] == _epoch && change['version'] == _identities[task.activity.key]?.version;
      var task = target();
      if (!matches(task)) return fail(409, 'native_task_changed');
      final action = change['action'] as String;
      if (!task!.actions.contains(action)) return fail(409, 'native_task_action_unavailable');
      if (!await claim()) return fail(409, 'operation_expired');
      tasks = _refresh();
      task = target();
      if (!matches(task) || !task!.actions.contains(action)) return fail(409, 'native_task_changed');
      // Consume this view before asynchronous effects: repeating the exact POST
      // never re-applies a still-waiting or canceling task.
      _identities[task.activity.key]!.version = _uuid.v4();
      final epoch = _epoch;
      await control(task, action);
      return response(200, {'epoch': epoch, 'id': value['taskId'] as String, 'action': action, 'dispatched': true});
    } on FormatException {
      return fail(400, 'invalid_body');
    } catch (_) {
      return fail(503, 'native_task_operation_failed');
    }
  }
}
