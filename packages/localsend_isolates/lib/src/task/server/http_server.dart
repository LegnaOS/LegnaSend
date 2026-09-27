import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/src/task/server/api_upload_source.dart';
import 'package:localsend_isolates/src/task/server/directory_document_provider.dart';
import 'package:localsend_isolates/src/task/server/directory_write_provider.dart';
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:localsend_isolates/src/task/server/receive_source_end_scope.dart';
import 'package:localsend_isolates/src/task/server/saf_receive_attempt.dart';
import 'package:localsend_isolates/util/saf_receive_transaction.dart';
import 'package:refena_flutter/refena_flutter.dart';

final httpServerProvider = Provider((ref) => HttpServerService());

/// Wraps the Rust HTTP server.
/// Only one server can run at a time.
class HttpServerService {
  Future<int> get boundPort => _requireServer().port();
  RsHttpServer? _server;
  // Exactly one observation handle. Core shares its bounded host history across
  // successful starts, so no retired-listener collection or disk wait is needed.
  RsHttpServer? _activityObserver;
  Stream<RsServerEvent>? _events;
  Future<void> _lifecycle = Future<void>.value();

  /// Serializes native bind/release, including the time before a handle exists.
  /// Failed operations do not prevent a later start from recovering.
  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  DirectoryWriteReply directoryWriteResponder(Stream<RsServerEvent> events) {
    if (!ownsEvents(events)) throw StateError('Workspace write listener is no longer current');
    final owner = _server!;
    return ({required requestId, payload, cacheDescriptor, stagingDescriptor, error}) => owner.respondDirectoryDocumentWrite(
      requestId: requestId,
      payload: payload,
      cacheDescriptor: cacheDescriptor,
      stagingDescriptor: stagingDescriptor,
      error: error,
    );
  }

  /// Source-end scope replies remain bound to the emitting server. A granted
  /// response completes only after its core worker has stopped using the scope.
  ReceiveSourceEndScopeReply receiveSourceEndScopeResponder(Stream<RsServerEvent> events) {
    if (!ownsEvents(events)) throw StateError('Source-end listener is no longer current');
    final owner = _server!;
    return ({required requestId, required granted}) => owner.respondReceiveSourceEndScope(requestId: requestId, granted: granted);
  }

  /// An old event loop may finish after stop has already enabled a replacement.
  /// Its finalizer must not clear the replacement listener's receive state.
  bool ownsEvents(Stream<RsServerEvent> events) => _server != null && identical(_events, events);

  /// A port lookup itself crosses the bridge and may complete after stop.
  Future<int?> boundPortFor(Stream<RsServerEvent> events) async {
    if (!ownsEvents(events)) return null;
    final server = _server!;
    try {
      final port = await server.port();
      return ownsEvents(events) ? port : null;
    } catch (_) {
      if (!ownsEvents(events)) return null;
      rethrow;
    }
  }

  DirectoryDocumentReply directoryDocumentResponder(Stream<RsServerEvent> events) {
    if (!ownsEvents(events)) throw StateError('Directory listener is no longer current');
    final owner = _server!;
    return ({required requestId, payload, fileDescriptor, error}) => owner.respondDirectoryDocument(
      requestId: requestId,
      payload: payload,
      fileDescriptor: fileDescriptor,
      error: error,
    );
  }

  bool get running => _server != null;

  Future<String> configureIntegrationApi(String config) => _requireServer().configureIntegrationApi(config: config);
  Future<String> integrationApiRequest(String request) {
    final server = _requireServer();
    return executeApiConsoleWithSource(
      request: request,
      isCurrent: () => identical(_server, server),
      execute: (request, fd) => server.integrationApiRequest(request: request, fileDescriptor: fd),
    );
  }

  Future<String> webDownloadActivity() {
    final observer = _activityObserver;
    if (observer == null) return Future.value('[]');
    return observer.webDownloadActivity();
  }

  Future<bool> cancelWebDownload(String id) => _requireServer().cancelWebDownload(id: id);

  Future<bool> directoryUploadApproval(String requestId, bool accept) =>
      _requireServer().respondDirectoryUploadApproval(requestId: requestId, accept: accept);

  Future<String> workspaceManagement(String requestId, String? response) async {
    final server = _requireServer();
    if (response == null) return (await server.claimWorkspaceManagement(requestId: requestId)).toString();
    await server.respondWorkspaceManagement(requestId: requestId, response: response);
    return 'ok';
  }

  Future<void> directoryContent(String requestId, String? response) =>
      _requireServer().respondDirectoryContent(requestId: requestId, response: response);

  Future<String> integrationApiSnapshot() => _requireServer().integrationApiSnapshot();

  Future<String> captureWorkspaceSources(String workspaceId, int generation, String files, String destination) =>
      _requireServer().captureWorkspaceSources(workspaceId: workspaceId, generation: BigInt.from(generation), files: files, destination: destination);

  Future<String> configureDirectoryWorkspaces(String config) => _requireServer().configureDirectoryWorkspaces(config: config);

  Future<void> setWebWorkspace({required bool enabled, required Map<String, FileDto> files, required String? pin, required bool allowUpload}) =>
      _requireServer().setWebWorkspace(enabled: enabled, files: files, pin: pin, allowUpload: allowUpload);

  Future<void> patchWebWorkspace({required Map<String, FileDto> files, required List<String> removeFileIds}) =>
      _requireServer().patchWebWorkspace(files: files, removeFileIds: removeFileIds);

  Future<void> updateWebWorkspace({required Map<String, FileDto> files, required bool allowUpload}) async {
    await _requireServer().updateWebWorkspace(files: files, allowUpload: allowUpload);
  }

  /// Starts the server and returns the stream of server events.
  /// The stream ends when the server is stopped.
  Future<Stream<RsServerEvent>> start({
    required int port,
    required TlsConfig? tls,
    required String alias,
    required String version,
    required String? deviceModel,
    required DeviceType? deviceType,
    required String fingerprint,
    required String? pin,
    required bool verifyChecksums,
    required WebParams web,
    required String? showToken,
  }) => _run(() async {
    if (_server != null) {
      throw StateError('Server already running');
    }

    final server = await startServer(
      port: port,
      tls: tls,
      alias: alias,
      version: version,
      deviceModel: deviceModel,
      deviceType: deviceType,
      fingerprint: fingerprint,
      pin: pin,
      verifyChecksums: verifyChecksums,
      web: web,
      showToken: showToken,
    );
    _server = server;
    _activityObserver = server;
    final events = _events = server.listen();
    return events;
  });

  /// Answers a pending prepare-upload request.
  /// [acceptedFileIds] is the subset of the offered files to accept; `null` declines the request.
  Future<bool> respondPrepareUpload({
    required String sessionId,
    required List<String>? acceptedFileIds,
    List<String>? resumableFileIds,
    List<String>? durableFileIds,
  }) async {
    return await _requireServer().respondPrepareUpload(
      sessionId: sessionId,
      acceptedFileIds: acceptedFileIds,
      resumableFileIds: resumableFileIds,
      durableFileIds: durableFileIds,
    );
  }

  Future<bool> supportsReceiveRecoveryTarget({required String approvedDirectory, required String requestedName}) async {
    final server = _requireServer();
    final supported = await server.supportsReceiveRecoveryTarget(approvedDirectory: approvedDirectory, requestedName: requestedName);
    return identical(_server, server) && supported;
  }

  /// Captures the emitting listener. A late target lookup never crosses into a
  /// replacement listener, even if an integration reuses session/file IDs.
  ReceiveRecoveryLookup receiveRecoveryLookup({
    required Stream<RsServerEvent> events,
    required String sessionId,
    required String fileId,
    required String attemptId,
  }) {
    final server = _requireServer();
    return ({required String approvedDirectory, required String requestedName}) async {
      if (!ownsEvents(events)) throw StateError('Receive listener no longer owns this target');
      final result = await server.lookupReceiveRecoveryTarget(
        sessionId: sessionId,
        fileId: fileId,
        expectedAttemptId: attemptId,
        approvedDirectory: approvedDirectory,
        requestedName: requestedName,
      );
      if (!ownsEvents(events)) throw StateError('Receive listener no longer owns this target');
      return ReceiveRecoveryTarget(path: result.path, receiptId: result.receiptId, completedUnixMs: result.completedUnixMs?.toInt());
    };
  }

  /// Answers a pending file upload with the target the file should be saved to
  /// (either a [path] or a [fileDescriptor]).
  ///
  /// The returned stream emits the progress (fraction of [fileSize]) while the
  /// file is being received and closes once the file has been received
  /// completely (or errors when saving failed).
  ///
  /// Timestamps provided in the sender's file metadata are applied to the
  /// written file by the Rust server.
  Stream<double> respondFileUpload({
    required String sessionId,
    required String fileId,
    required String? path,
    required int? fileDescriptor,
    required int fileSize,
    String? expectedAttemptId,
  }) {
    final server = _server;
    if (server == null) {
      // A SAF open may finish after stop(). Consume its detached descriptor even
      // though the request can no longer be handed to the stopped Rust server.
      final released = fileDescriptor == null ? Future<void>.value() : discardDownloadSource(path: null, fileDescriptor: fileDescriptor);
      return Stream<double>.fromFuture(released.then<double>((_) => throw StateError('Server is not running')));
    }
    return server.respondFileUpload(
      sessionId: sessionId,
      fileId: fileId,
      path: path,
      fileDescriptor: fileDescriptor,
      fileSize: BigInt.from(fileSize),
      expectedAttemptId: expectedAttemptId,
    );
  }

  /// Consumes both descriptors even when server shutdown won the preparation race.
  Stream<double> respondCachedFileUpload({required SafReceiveAttempt attempt, required int fileSize}) {
    if (attempt.descriptorsHandedOff) return Stream.error(StateError('Receive descriptors already transferred'));
    attempt.descriptorsHandedOff = true;
    final server = _server;
    if (server == null) {
      final released = discardSafDescriptors([attempt.opened.cacheFd, attempt.opened.stagingFd]);
      return Stream<double>.fromFuture(released.then<double>((_) => throw StateError('Server is not running')));
    }
    return server.respondCachedFileUpload(
      sessionId: attempt.sessionId,
      fileId: attempt.fileId,
      transactionId: attempt.transactionId,
      cacheDescriptor: attempt.opened.cacheFd,
      stagingDescriptor: attempt.opened.stagingFd,
      fileSize: BigInt.from(fileSize),
    );
  }

  /// Identity binding is an internal write-before-resume gate, not approval.
  Future<bool> respondReceiveCacheIdentity({
    required String sessionId,
    required String fileId,
    required String attemptId,
    required String transactionId,
    required String? error,
    SafReceiveRecovery? recovery,
  }) async {
    final server = _server;
    if (server == null) {
      if (recovery != null) await discardSafDescriptors([recovery.sourceFd]);
      return false;
    }
    return server.respondReceiveCacheIdentity(
      sessionId: sessionId,
      fileId: fileId,
      attemptId: attemptId,
      transactionId: transactionId,
      error: error,
      recoveryTransactionId: recovery?.transactionId,
      recoveryIdentityJson: recovery?.identityJson,
      recoverySourceDescriptor: recovery?.sourceFd,
    );
  }

  Future<bool> respondReceiveCacheRecovered({
    required String sessionId,
    required String fileId,
    required String attemptId,
    required String transactionId,
    required String? error,
  }) async {
    final server = _server;
    if (server == null) return false;
    return server.respondReceiveCacheRecovered(
      sessionId: sessionId,
      fileId: fileId,
      attemptId: attemptId,
      transactionId: transactionId,
      error: error,
    );
  }

  /// Internal publication gate. A missing/stopped server cannot approve a stale attempt.
  Future<bool> respondUploadPublication({
    required String sessionId,
    required String fileId,
    required String attemptId,
    required String transactionId,
    required String? error,
  }) async {
    final server = _server;
    if (server == null) return false;
    return server.respondUploadPublication(
      sessionId: sessionId,
      fileId: fileId,
      attemptId: attemptId,
      transactionId: transactionId,
      error: error,
    );
  }

  /// Fails a pending file upload, e.g. because no save target could be
  /// prepared. The upload request fails with an error response and the file is
  /// marked as failed; the session itself continues.
  /// Does nothing if the upload was already answered via [respondFileUpload].
  Future<void> failFileUpload({required String sessionId, required String fileId, String? expectedAttemptId}) async {
    await _requireServer().failFileUpload(sessionId: sessionId, fileId: fileId, expectedAttemptId: expectedAttemptId);
  }

  /// Cancels the active upload session. Uploads that are already in progress
  /// still run to completion, but new upload requests fail and a new
  /// session can be created. No session-end event is emitted.
  Future<void> cancelSession({required String sessionId}) async {
    await _requireServer().cancelSession(sessionId: sessionId);
  }

  /// Answers a pending web prepare-download request.
  /// [accept] grants the download; `false` declines it.
  Future<void> respondPrepareDownload({required String sessionId, required bool accept}) async {
    await _requireServer().respondPrepareDownload(sessionId: sessionId, accept: accept);
  }

  /// Answers a pending web file download with the source the file content should be
  /// read from (either a [path] or a [fileDescriptor]). The server streams the content.
  Future<bool> respondFileDownload({
    required String requestId,
    required String sessionId,
    required String fileId,
    required String? path,
    required int? fileDescriptor,
  }) async {
    final server = _server;
    if (server == null) {
      await discardDownloadSource(path: path, fileDescriptor: fileDescriptor);
      return false;
    }
    return await server.respondFileDownload(
      requestId: requestId,
      sessionId: sessionId,
      fileId: fileId,
      path: path,
      fileDescriptor: fileDescriptor,
    );
  }

  /// Fails a pending web file download, e.g. because no content source could
  /// be resolved. The download request fails with an error response.
  /// Does nothing if the download was already answered via [respondFileDownload].
  Future<void> failFileDownload({required String requestId, required String sessionId, required String fileId}) async {
    await _server?.failFileDownload(requestId: requestId, sessionId: sessionId, fileId: fileId);
  }

  /// Stops the server. The event stream returned by [start] will end.
  /// Completes once the port is released and can be bound again.
  Future<void> stop({Stream<RsServerEvent>? expectedEvents}) => _run(() async {
    if (expectedEvents != null && !ownsEvents(expectedEvents)) return;
    final server = _server;
    _server = null;
    _events = null;
    await server?.stop();
  });

  /// Stop and observe the same handle, never a replacement listener. Active
  /// publication may still be unresolved; callers must not infer cancellation.
  Future<String?> stopWithActivity() => _run(() async {
    final server = _server;
    _server = null;
    _events = null;
    await server?.stop();
    try {
      return await webDownloadActivity();
    } catch (_) {
      return null;
    }
  });

  RsHttpServer _requireServer() {
    final server = _server;
    if (server == null) {
      throw StateError('Server is not running');
    }
    return server;
  }
}
