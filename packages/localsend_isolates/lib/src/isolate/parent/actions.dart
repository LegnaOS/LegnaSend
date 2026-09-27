import 'dart:async';

import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/api/server.dart' show WebParams;
import 'package:localsend_isolates/src/isolate/child/discovery_isolate.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/isolate/child/upload_isolate.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/src/isolate/parent/parent_isolate_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:typed_isolates/id.dart';
import 'package:typed_isolates/typed_isolates.dart';

/// Starts the discovery and returns the stream of confirmed devices:
/// answered announcements, scan results and devices fed in via
/// [IsolateDiscoveryAddDeviceAction] all arrive on this one stream.
/// The stream never completes; it survives [IsolateDiscoveryRestartAction]s.
class IsolateDiscoveryListenAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, Stream<Device>> {
  @override
  (ParentIsolateState, Stream<Device>) reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    return (
      state,
      connection
          .sendWrappedTaskAndListenStream(
            task: DiscoveryListenTask(),
          )
          .toDeviceStream(),
    );
  }
}

/// Scans the subnet of one network interface over HTTP,
/// for networks that do not carry multicast.
/// The returned stream completes (without events) when the scan is finished;
/// the found devices arrive on the [IsolateDiscoveryListenAction] stream.
class IsolateDiscoverySubnetScanAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, Stream<Device>> {
  final String networkInterface;
  final int port;
  final bool https;

  IsolateDiscoverySubnetScanAction({
    required this.networkInterface,
    required this.port,
    required this.https,
  });

  @override
  (ParentIsolateState, Stream<Device>) reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    return (
      state,
      connection
          .sendWrappedTaskAndListenStream(
            task: DiscoverySubnetScanTask(
              networkInterface: networkInterface,
              port: port,
              https: https,
            ),
          )
          .toDeviceStream(),
    );
  }
}

/// Discovers devices in stages, cheapest first: announcement and favorite
/// probes right away, a subnet scan only when nothing was confirmed within
/// the grace period.
/// The returned stream completes (without events) when every stage has
/// finished; the found devices arrive on the [IsolateDiscoveryListenAction]
/// stream.
class IsolateDiscoveryStagedScanAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, Stream<Device>> {
  final List<(String, int)> favorites;
  final List<String> networkInterfaces;
  final int port;
  final bool https;
  final Duration grace;

  IsolateDiscoveryStagedScanAction({
    required this.favorites,
    required this.networkInterfaces,
    required this.port,
    required this.https,
    required this.grace,
  });

  @override
  (ParentIsolateState, Stream<Device>) reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    return (
      state,
      connection
          .sendWrappedTaskAndListenStream(
            task: DiscoveryStagedScanTask(
              favorites: favorites,
              networkInterfaces: networkInterfaces,
              port: port,
              https: https,
              grace: grace,
            ),
          )
          .toDeviceStream(),
    );
  }
}

/// Fetches the retained confirmations of a stored device, oldest first.
/// The logs are empty when the fingerprint is unknown or the discovery is
/// not running.
class IsolateDiscoveryDeviceLogsAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, List<DeviceLog>> {
  final String fingerprint;

  IsolateDiscoveryDeviceLogsAction({
    required this.fingerprint,
  });

  @override
  Future<(ParentIsolateState, List<DeviceLog>)> reduce() async {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    final result = await connection
        .sendWrappedTaskAndListenStream(
          task: DiscoveryDeviceLogsTask(fingerprint: fingerprint),
        )
        .first;

    return (state, (result as DiscoveryDeviceLogsResult).logs);
  }
}

/// Sends an announcement which makes every other LocalSend device on the
/// network register with this device's HTTP server.
class IsolateDiscoveryAnnouncementAction extends ReduxAction<IsolateController, ParentIsolateState> {
  @override
  ParentIsolateState reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: DiscoveryAnnouncementTask(),
        ),
      ),
    );

    return state;
  }
}

/// Restarts the discovery, e.g. after the port or the network settings changed.
class IsolateDiscoveryRestartAction extends ReduxAction<IsolateController, ParentIsolateState> {
  @override
  ParentIsolateState reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: DiscoveryRestartTask(),
        ),
      ),
    );

    return state;
  }
}

/// Feeds a device confirmed outside of the discovery into the discovery store,
/// e.g. one that registered with this device's HTTP server. The device comes
/// back on the [IsolateDiscoveryListenAction] stream.
class IsolateDiscoveryAddDeviceAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final Device device;

  IsolateDiscoveryAddDeviceAction({
    required this.device,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.discovery;
    if (connection == null) {
      throw StateError('discovery is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: DiscoveryAddDeviceTask(
            device: device,
          ),
        ),
      ),
    );

    return state;
  }
}

class IsolateHttpUploadActionResult {
  final int taskId;
  final Stream<HttpUploadEvent> events;

  IsolateHttpUploadActionResult({
    required this.taskId,
    required this.events,
  });
}

class IsolateHttpUploadFilesAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, IsolateHttpUploadActionResult> {
  final String? remoteSessionId;
  final List<HttpUploadFile> files;
  final Device device;
  final LocalSendRoute? localRoute;

  IsolateHttpUploadFilesAction({
    required this.remoteSessionId,
    required this.files,
    required this.device,
    this.localRoute,
  });

  @override
  (ParentIsolateState, IsolateHttpUploadActionResult) reduce() {
    final connection = state.httpUpload;
    if (connection == null) {
      throw StateError('httpUpload is not initialized');
    }
    final taskId = IdProvider.instance.getNextId();
    final events = connection.sendWrappedTaskAndListenStream(
      task: HttpUploadFilesTask(
        remoteSessionId: remoteSessionId,
        files: files,
        device: device,
        localRoute: localRoute,
      ),
      taskId: taskId,
    );

    return (
      state,
      IsolateHttpUploadActionResult(
        taskId: taskId,
        events: events,
      ),
    );
  }
}

class IsolateHttpSourceEndAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, IsolateHttpUploadActionResult> {
  final Device target;
  final LocalSendRoute? localRoute;
  final SourceEndGrant grant;
  final String requestId;
  IsolateHttpSourceEndAction({required this.target, required this.localRoute, required this.grant, required this.requestId});
  @override
  (ParentIsolateState, IsolateHttpUploadActionResult) reduce() {
    final connection = state.httpUpload;
    if (connection == null) throw StateError('Upload isolate unavailable');
    final id = IdProvider.instance.getNextId();
    final events = connection.sendWrappedTaskAndListenStream(
      task: HttpSourceEndTask(target: target, localRoute: localRoute, grant: grant, requestId: requestId),
      taskId: id,
    );
    return (state, IsolateHttpUploadActionResult(taskId: id, events: events));
  }

  @override
  String toString() => 'IsolateHttpSourceEndAction(redacted)';
}

class IsolateHttpSourceEndAckAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final int uploadTaskId;
  final String fileId, ackId;
  final bool persisted;
  IsolateHttpSourceEndAckAction({required this.uploadTaskId, required this.fileId, required this.ackId, required this.persisted});
  @override
  ParentIsolateState reduce() {
    state.httpUpload?.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpSourceEndAckTask(uploadTaskId: uploadTaskId, fileId: fileId, ackId: ackId, persisted: persisted),
        ),
      ),
    );
    return state;
  }
}

class IsolateHttpUploadCancelAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final int taskId;

  IsolateHttpUploadCancelAction({
    required this.taskId,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.httpUpload;
    if (connection == null) {
      throw StateError('httpUpload is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpUploadCancelTask(
            taskId: taskId,
          ),
        ),
      ),
    );

    return state;
  }
}

/// Starts the HTTP server and returns the stream of server events.
/// The stream ends when the server is stopped via [IsolateHttpServerStopAction].
class IsolateHttpServerStartAction extends ReduxActionWithResult<IsolateController, ParentIsolateState, Stream<HttpServerEvent>> {
  final String? pin;

  /// Whether the SHA-256 checksums that senders provide for their files are
  /// verified after receiving.
  final bool verifyChecksums;

  /// Configures the pages served to browsers: the download page (web download),
  /// the upload page, or the 403 page when web share is disabled.
  final WebParams web;

  /// Enables the internal `show` endpoint, guarded by this token, that lets another
  /// application instance request this one to show itself. `null` disables it.
  final String? showToken;

  IsolateHttpServerStartAction({
    required this.pin,
    required this.verifyChecksums,
    required this.web,
    required this.showToken,
  });

  @override
  (ParentIsolateState, Stream<HttpServerEvent>) reduce() {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    return (
      state,
      connection.sendWrappedTaskAndListenStream(
        task: HttpServerStartTask(
          pin: pin,
          verifyChecksums: verifyChecksums,
          web: web,
          showToken: showToken,
        ),
      ),
    );
  }
}

/// Stops the HTTP server.
/// Completes once the server has released the port, so the port can be bound again.
class IsolateHttpServerStopAction extends AsyncReduxAction<IsolateController, ParentIsolateState> {
  @override
  Future<ParentIsolateState> reduce() async {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    await connection
        .sendWrappedTaskAndListenStream(
          task: HttpServerStopTask(),
        )
        .drain<void>();

    return state;
  }
}

/// Retains the stopped listener's final bounded activity snapshot in the stop
/// RPC result, independent from its already-closed event subscription.
class IsolateHttpServerStopWithActivityAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerStopTask(captureActivity: true)).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement);
  }
}

class IsolateHttpServerSetWorkspaceAction extends AsyncReduxAction<IsolateController, ParentIsolateState> {
  final bool enabled;
  final Map<String, rust.FileDto> files;
  final String? pin;
  final bool allowUpload;
  IsolateHttpServerSetWorkspaceAction({required this.enabled, this.files = const {}, this.pin, this.allowUpload = false});
  @override
  String toString() => 'IsolateHttpServerSetWorkspaceAction(redacted)';
  @override
  Future<ParentIsolateState> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    await connection
        .sendWrappedTaskAndListenStream(
          task: HttpServerSetWorkspaceTask(enabled: enabled, files: files, pin: pin, allowUpload: allowUpload),
        )
        .drain<void>();
    return state;
  }
}

/// Applies app-owned workspace settings without ending the server event stream.
class IsolateHttpServerPatchWorkspaceAction extends AsyncReduxAction<IsolateController, ParentIsolateState> {
  final Map<String, rust.FileDto> files;
  final List<String> removeFileIds;
  IsolateHttpServerPatchWorkspaceAction({required this.files, required this.removeFileIds});
  @override
  String toString() => 'IsolateHttpServerPatchWorkspaceAction(additions: ${files.length}, removals: ${removeFileIds.length})';
  @override
  Future<ParentIsolateState> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    await connection
        .sendWrappedTaskAndListenStream(
          task: HttpServerPatchWorkspaceTask(files: files, removeFileIds: removeFileIds),
        )
        .drain<void>();
    return state;
  }
}

class IsolateHttpServerUpdateWorkspaceAction extends AsyncReduxAction<IsolateController, ParentIsolateState> {
  final Map<String, rust.FileDto> files;
  final bool allowUpload;
  IsolateHttpServerUpdateWorkspaceAction({required this.files, required this.allowUpload});
  @override
  Future<ParentIsolateState> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    await connection
        .sendWrappedTaskAndListenStream(
          task: HttpServerUpdateWorkspaceTask(files: files, allowUpload: allowUpload),
        )
        .drain<void>();
    return state;
  }
}

/// Answers a pending [HttpServerPrepareUploadEvent].
///
/// When accepted, the server isolate receives all files on its own and
/// reports [HttpServerFileUploadEvent], [HttpServerFileUploadProgressEvent]
/// and [HttpServerFileUploadResultEvent] on the server event stream.
class IsolateHttpServerPrepareUploadDecisionAction extends ReduxAction<IsolateController, ParentIsolateState> {
  /// The receive configuration including the accepted file IDs.
  /// `null` declines the request.
  final HttpServerReceiveConfig? config;
  final String sessionId;

  IsolateHttpServerPrepareUploadDecisionAction({
    required this.config,
    required this.sessionId,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpServerPrepareUploadDecisionTask(
            config: config,
            sessionId: sessionId,
          ),
        ),
      ),
    );

    return state;
  }
}

/// Cancels the active upload session of the HTTP server, e.g. because the
/// user aborted the transfer on the receiving side.
/// No [HttpServerSessionEndEvent] is emitted.
class IsolateHttpServerCancelSessionAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final String sessionId;

  IsolateHttpServerCancelSessionAction({
    required this.sessionId,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpServerCancelSessionTask(
            sessionId: sessionId,
          ),
        ),
      ),
    );

    return state;
  }
}

/// Answers a pending [HttpServerWebPrepareDownloadEvent].
class IsolateHttpServerPrepareDownloadDecisionAction extends AsyncReduxAction<IsolateController, ParentIsolateState> {
  final String sessionId;
  final bool accept;
  IsolateHttpServerPrepareDownloadDecisionAction({required this.sessionId, required this.accept});

  @override
  Future<ParentIsolateState> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    await connection
        .sendWrappedTaskAndListenStream(
          task: HttpServerPrepareDownloadDecisionTask(sessionId: sessionId, accept: accept),
        )
        .drain<void>();
    return state;
  }
}

/// Answers a pending [HttpServerWebFileDownloadEvent] with the source the file
/// content should be read from (either a [path] or a readable [fileDescriptor]).
class IsolateHttpServerFileDownloadTargetAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final String requestId;
  final String sessionId;
  final String fileId;
  final String? path;
  final int? fileDescriptor;

  IsolateHttpServerFileDownloadTargetAction({
    required this.requestId,
    required this.sessionId,
    required this.fileId,
    required this.path,
    required this.fileDescriptor,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpServerFileDownloadTargetTask(
            requestId: requestId,
            sessionId: sessionId,
            fileId: fileId,
            path: path,
            fileDescriptor: fileDescriptor,
          ),
        ),
      ),
    );

    return state;
  }
}

/// Fails a pending [HttpServerWebFileDownloadEvent], e.g. because no source
/// for the file content could be resolved. The web client receives an error
/// response for this file.
/// Does nothing if the download was already answered with a
/// [IsolateHttpServerFileDownloadTargetAction].
class IsolateHttpServerFailFileDownloadAction extends ReduxAction<IsolateController, ParentIsolateState> {
  final String requestId;
  final String sessionId;
  final String fileId;

  IsolateHttpServerFailFileDownloadAction({
    required this.requestId,
    required this.sessionId,
    required this.fileId,
  });

  @override
  ParentIsolateState reduce() {
    final connection = state.httpServer;
    if (connection == null) {
      throw StateError('httpServer is not initialized');
    }

    connection.sendToIsolate(
      SendToIsolateData(
        syncState: null,
        data: IsolateTask(
          data: HttpServerFailFileDownloadTask(
            requestId: requestId,
            sessionId: sessionId,
            fileId: fileId,
          ),
        ),
      ),
    );

    return state;
  }
}

extension _DeviceStreamExt on Stream<DiscoveryResult> {
  /// Unwraps the [DiscoveryDeviceResult]s of a device stream.
  Stream<Device> toDeviceStream() {
    return map((result) => (result as DiscoveryDeviceResult).device);
  }
}

/// Adds the [SendToIsolateData] envelope on top of the generic
/// [IsolateTaskConnector.sendTaskAndListenStream] from `typed_isolates`.
extension _WrappedTaskConnector<R, T> on IsolateConnector<IsolateTaskStreamResult<R>, SendToIsolateData<IsolateTask<T>>> {
  /// Sends a [task] wrapped in a [SendToIsolateData] envelope and transforms
  /// the responded [IsolateTaskStreamResult]s into a plain [Stream].
  Stream<R> sendWrappedTaskAndListenStream({
    required T task,
    int? taskId,
  }) {
    final wrappedTask = IsolateTask(
      id: taskId,
      data: task,
    );

    // ignore: discarded_futures
    Future.microtask(() {
      sendToIsolate(
        SendToIsolateData(
          syncState: null,
          data: wrappedTask,
        ),
      );
    });

    return convertResponseToStream(taskId: wrappedTask.id);
  }
}

/// Application-only directory configuration through the existing server isolate.
class IsolateHttpServerDirectoryCatalogAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  final String config;
  IsolateHttpServerDirectoryCatalogAction(this.config);

  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerDirectoryCatalogTask(config)).first;
    return (state, (result as HttpServerDirectoryCatalogResult).acknowledgement);
  }
}

/// Configuration remains outside parent state; results contain only redacted metadata.
class IsolateHttpServerIntegrationAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  final String? configuration;
  final String? consoleRequest;
  IsolateHttpServerIntegrationAction({this.configuration, this.consoleRequest});
  @override
  String toString() => 'IsolateHttpServerIntegrationAction(redacted)';
  @override
  String describeResult(String result) => 'Integration API metadata (redacted)';
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection
        .sendWrappedTaskAndListenStream(task: HttpServerIntegrationTask(configuration, consoleRequest: consoleRequest))
        .first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement);
  }
}

/// Private observation receipt; source locators never enter logged Redux state.
class IsolateHttpServerDirectoryContentAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  final String requestId;
  final String? response;
  IsolateHttpServerDirectoryContentAction({required this.requestId, required this.response});
  @override
  String toString() => 'IsolateHttpServerDirectoryContentAction(redacted)';
  @override
  String describeResult(String result) => 'Workspace content receipt';
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerDirectoryContentTask(requestId, response)).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement);
  }
}

/// Claim/complete a core-authorized host mutation without exposing source paths in logs.
class IsolateHttpServerWorkspaceManagementAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  final String requestId;
  final String? response;
  IsolateHttpServerWorkspaceManagementAction({required this.requestId, this.response});
  @override
  String toString() => 'IsolateHttpServerWorkspaceManagementAction(redacted)';
  @override
  String describeResult(String result) => 'Workspace management receipt (redacted)';
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerWorkspaceManagementTask(requestId, response)).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement);
  }
}

class IsolateHttpServerDirectoryUploadApprovalAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, bool> {
  final String requestId;
  final bool accept;
  IsolateHttpServerDirectoryUploadApprovalAction({required this.requestId, required this.accept});
  @override
  Future<(ParentIsolateState, bool)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerDirectoryUploadApprovalTask(requestId, accept)).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement == 'true');
  }
}

class IsolateHttpServerCancelWebDownloadAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, bool> {
  final String requestId;
  IsolateHttpServerCancelWebDownloadAction({required this.requestId});
  @override
  Future<(ParentIsolateState, bool)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerCancelWebDownloadTask(requestId)).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement == 'true');
  }
}

class IsolateHttpServerCaptureWorkspaceSourcesAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  final String workspaceId;
  final int generation;
  final String files;
  final String destination;
  IsolateHttpServerCaptureWorkspaceSourcesAction({
    required this.workspaceId,
    required this.generation,
    required this.files,
    required this.destination,
  });
  @override
  String toString() => 'IsolateHttpServerCaptureWorkspaceSourcesAction(redacted)';
  @override
  String describeResult(String result) => 'Workspace source capture (redacted)';
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection
        .sendWrappedTaskAndListenStream(task: HttpServerCaptureWorkspaceSourcesTask(workspaceId, generation, files, destination))
        .first;
    return (state, (result as HttpServerDirectoryCatalogResult).acknowledgement);
  }
}

/// Pull-based activity observation: the caller waits for consumption before
/// requesting another snapshot, so a stalled UI cannot accumulate snapshots.
class IsolateHttpServerWebDownloadSnapshotAction extends AsyncReduxActionWithResult<IsolateController, ParentIsolateState, String> {
  @override
  Future<(ParentIsolateState, String)> reduce() async {
    final connection = state.httpServer;
    if (connection == null) throw StateError('httpServer is not initialized');
    final result = await connection.sendWrappedTaskAndListenStream(task: HttpServerWebDownloadSnapshotTask()).first;
    return (state, (result as HttpServerIntegrationResult).acknowledgement);
  }
}

/// Successful receipt delivery follows the child connection, not a listener
/// task stream. A saved file may finish post-processing after its start task
/// already emitted `done`; the connection still carries that immutable receipt.
/// Consumers must use this stream for history only, never session/UI routing.
/// It has no replay cache and does not survive disposal of the child isolate.
Stream<HttpServerFileUploadResultEvent> httpServerReceiveReceiptStream(ParentIsolateState state) {
  final connection = state.httpServer;
  if (connection == null) return const Stream.empty();
  return connection.receiveFromIsolate
      .map((result) => result.data)
      .where((event) => event is HttpServerFileUploadResultEvent && event.error == null && event.receipt != null)
      .cast<HttpServerFileUploadResultEvent>();
}
