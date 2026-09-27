import 'dart:async';

import 'package:localsend_app/model/directory_upload_approval.dart';
import 'package:refena_flutter/refena_flutter.dart';

final directoryUploadApprovalProvider = NotifierProvider<DirectoryUploadApprovalNotifier, List<DirectoryUploadApproval>>(
  (_) => DirectoryUploadApprovalNotifier(),
);

/// UI-side decisions are keyed by request ID; navigation never calls a responder.
class DirectoryUploadApprovalNotifier extends PureNotifier<List<DirectoryUploadApproval>> {
  final DateTime Function() now;
  final _responders = <String, Future<void> Function(bool)>{};
  final _timers = <String, Timer>{};
  final _identities = <String, Object>{};
  bool _disposed = false;
  DirectoryUploadApprovalNotifier({DateTime Function()? now}) : now = now ?? DateTime.now;

  @override
  List<DirectoryUploadApproval> init() => [];

  void add(DirectoryUploadApproval request, {required Future<void> Function(bool accept) respond}) {
    if (_disposed || state.any((entry) => entry.requestId == request.requestId)) return;
    final expired = request.expiresAt <= now().millisecondsSinceEpoch;
    final snapshot = DirectoryUploadApproval(
      requestId: request.requestId,
      workspaceId: request.workspaceId,
      workspaceName: request.workspaceName,
      files: List.unmodifiable(request.files),
      peerIp: request.peerIp,
      expiresAt: request.expiresAt,
      status: expired ? DirectoryUploadApprovalStatus.expired : DirectoryUploadApprovalStatus.waiting,
    );
    _identities[request.requestId] = Object();
    state = [...state, snapshot];
    if (!expired) {
      _responders[request.requestId] = respond;
      _timers[request.requestId] = Timer(Duration(milliseconds: request.expiresAt - now().millisecondsSinceEpoch), () => _expire(request.requestId));
    }
    _trimHistory();
  }

  void _replace(String id, DirectoryUploadApprovalStatus status) {
    if (_disposed) return;
    state = [
      for (final request in state)
        if (request.requestId == id) request.withStatus(status) else request,
    ];
  }

  void _expire(String id) {
    _timers.remove(id)?.cancel();
    _responders.remove(id);
    final current = state.where((request) => request.requestId == id).firstOrNull;
    if (current != null && current.pending) _replace(id, DirectoryUploadApprovalStatus.expired);
    _trimHistory();
  }

  Future<void> decide(String requestId, bool accept) async {
    final current = state.where((request) => request.requestId == requestId).firstOrNull;
    if (_disposed || current == null || current.status != DirectoryUploadApprovalStatus.waiting) return;
    if (current.expiresAt <= now().millisecondsSinceEpoch) {
      _expire(requestId);
      return;
    }
    final identity = _identities[requestId];
    final responder = _responders.remove(requestId);
    if (responder == null) return;
    _replace(requestId, DirectoryUploadApprovalStatus.responding);
    try {
      await responder(accept);
      if (_disposed ||
          _identities[requestId] != identity ||
          state.where((request) => request.requestId == requestId && request.status == DirectoryUploadApprovalStatus.responding).isEmpty) {
        return;
      }
      // Only the typed bridge responder's success confirms server acceptance.
      _replace(requestId, accept ? DirectoryUploadApprovalStatus.accepted : DirectoryUploadApprovalStatus.declined);
    } catch (_) {
      if (!_disposed &&
          _identities[requestId] == identity &&
          state.any((request) => request.requestId == requestId && request.status == DirectoryUploadApprovalStatus.responding)) {
        _replace(
          requestId,
          current.expiresAt <= now().millisecondsSinceEpoch ? DirectoryUploadApprovalStatus.expired : DirectoryUploadApprovalStatus.failed,
        );
      }
    } finally {
      if (_identities[requestId] == identity) _timers.remove(requestId)?.cancel();
      _trimHistory();
    }
  }

  /// Browser abort or server expiry removes exactly this card, never another batch.
  void aborted(String requestId) {
    _identities.remove(requestId);
    _responders.remove(requestId);
    _timers.remove(requestId)?.cancel();
    if (!_disposed) state = state.where((request) => request.requestId != requestId).toList();
  }

  /// Server shutdown invalidates pending responders without changing completed history.
  void abortAll() {
    final ids = state.where((request) => request.pending).map((request) => request.requestId).toList();
    for (final id in ids) {
      aborted(id);
    }
  }

  void clearFinished() {
    if (!_disposed) {
      for (final request in state.where((request) => !request.pending)) {
        _identities.remove(request.requestId);
      }
      state = state.where((request) => request.pending).toList();
    }
  }

  void _trimHistory() {
    if (_disposed) return;
    final terminal = state.where((request) => !request.pending).toList();
    if (terminal.length <= 20) return;
    final retain = terminal.skip(terminal.length - 20).map((request) => request.requestId).toSet();
    for (final request in terminal.where((request) => !retain.contains(request.requestId))) {
      _identities.remove(request.requestId);
    }
    state = state.where((request) => request.pending || retain.contains(request.requestId)).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _responders.clear();
    _identities.clear();
    super.dispose();
  }
}
