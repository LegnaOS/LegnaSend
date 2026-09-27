import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/rust/api/model.dart' show FileDto;
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/sync_provider.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/src/task/server/directory_document_provider.dart';
import 'package:localsend_isolates/src/task/server/directory_write_provider.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/http_server.dart';
import 'package:localsend_isolates/src/task/server/receive_recovery_target.dart';
import 'package:localsend_isolates/src/task/server/receive_resume_capability.dart';
import 'package:localsend_isolates/src/task/server/receive_scope_owner.dart';
import 'package:localsend_isolates/src/task/server/receive_source_end_scope.dart';
import 'package:localsend_isolates/src/task/server/saf_receive_attempt.dart';
import 'package:localsend_isolates/util/future_queue.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';
import 'package:localsend_isolates/util/receive_path_reservations.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:typed_isolates/typed_isolates.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('HttpServerIsolate');

sealed class BaseHttpServerTask {}

/// Starts the HTTP server.
/// The device information is derived from the sync state.
///
/// The server emits [HttpServerEvent]s on the stream of this task
/// until the server is stopped via [HttpServerStopTask].
class HttpServerStartTask implements BaseHttpServerTask {
  /// Optional PIN that senders must provide to start an upload session.
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

  HttpServerStartTask({
    required this.pin,
    required this.verifyChecksums,
    required this.web,
    required this.showToken,
  });
}

/// Stops the HTTP server.
/// The stream of this task completes once the server has released the port.
class HttpServerStopTask implements BaseHttpServerTask {
  final bool captureActivity;
  HttpServerStopTask({this.captureActivity = false});
}

class HttpServerCaptureWorkspaceSourcesTask implements BaseHttpServerTask {
  final String workspaceId;
  final int generation;
  final String files;
  final String destination;
  HttpServerCaptureWorkspaceSourcesTask(this.workspaceId, this.generation, this.files, this.destination);
  @override
  String toString() => 'HttpServerCaptureWorkspaceSourcesTask(redacted)';
}

class HttpServerDirectoryCatalogTask implements BaseHttpServerTask {
  final String config;
  HttpServerDirectoryCatalogTask(this.config);
}

class HttpServerDirectoryCatalogResult extends HttpServerEvent {
  final String acknowledgement;
  HttpServerDirectoryCatalogResult(this.acknowledgement);
}

/// A console request executes a catalog read; otherwise null configuration reads
/// metadata and policy writes remain local application control.
class HttpServerIntegrationTask implements BaseHttpServerTask {
  final String? configuration;
  final String? consoleRequest;
  HttpServerIntegrationTask(this.configuration, {this.consoleRequest});
  @override
  String toString() => 'HttpServerIntegrationTask(redacted)';
}

class HttpServerWebDownloadSnapshotTask implements BaseHttpServerTask {}

class HttpServerCancelWebDownloadTask implements BaseHttpServerTask {
  final String requestId;
  HttpServerCancelWebDownloadTask(this.requestId);
}

class HttpServerWebDownloadActivityEvent extends HttpServerEvent {
  final String snapshot;
  HttpServerWebDownloadActivityEvent(this.snapshot);
  @override
  String toString() => 'HttpServerWebDownloadActivityEvent(redacted)';
}

class HttpServerDirectoryUploadApprovalTask implements BaseHttpServerTask {
  final String requestId;
  final bool accept;
  HttpServerDirectoryUploadApprovalTask(this.requestId, this.accept);
}

class HttpServerDirectoryContentTask implements BaseHttpServerTask {
  final String requestId;
  final String? response;
  HttpServerDirectoryContentTask(this.requestId, this.response);
  @override
  String toString() => 'HttpServerDirectoryContentTask(redacted)';
}

class HttpServerWorkspaceManagementTask implements BaseHttpServerTask {
  final String requestId;
  final String? response;
  HttpServerWorkspaceManagementTask(this.requestId, this.response);
  @override
  String toString() => 'HttpServerWorkspaceManagementTask(redacted)';
}

class HttpServerIntegrationResult extends HttpServerEvent {
  final String acknowledgement;
  HttpServerIntegrationResult(this.acknowledgement);
}

class HttpServerSetWorkspaceTask implements BaseHttpServerTask {
  final bool enabled;
  final Map<String, FileDto> files;
  final String? pin;
  final bool allowUpload;
  HttpServerSetWorkspaceTask({required this.enabled, required this.files, required this.pin, required this.allowUpload});
  @override
  String toString() => 'HttpServerSetWorkspaceTask(redacted)';
}

class HttpServerPatchWorkspaceTask implements BaseHttpServerTask {
  final Map<String, FileDto> files;
  final List<String> removeFileIds;
  HttpServerPatchWorkspaceTask({required this.files, required this.removeFileIds});
  @override
  String toString() => 'HttpServerPatchWorkspaceTask(additions: ${files.length}, removals: ${removeFileIds.length})';
}

class HttpServerUpdateWorkspaceTask implements BaseHttpServerTask {
  final Map<String, FileDto> files;
  final bool allowUpload;
  HttpServerUpdateWorkspaceTask({required this.files, required this.allowUpload});
}

/// Everything the server isolate needs to receive the accepted files on its
/// own, without further involvement of the main isolate.
class HttpServerReceiveConfig {
  /// The session ID of the [HttpServerPrepareUploadEvent] being answered.
  final String sessionId;

  /// The accepted file IDs mapped to the desired file name
  /// (may contain a relative directory prefix).
  final Map<String, String> fileNameMap;

  final String destinationDirectory;

  /// Snapshot of the sender label, retained by an in-flight file after the
  /// active session changes. This is presentation metadata, not peer identity.
  final String senderAlias;

  /// Used as intermediate storage when [saveToGallery] is enabled.
  final String cacheDirectory;

  /// Save received images/videos to the OS gallery instead of
  /// [destinationDirectory].
  final bool saveToGallery;

  /// The Android SDK version, `null` on other platforms. Enables SAF handling
  /// for destinations that cannot be written directly.
  final int? androidSdkInt;

  HttpServerReceiveConfig({
    required this.sessionId,
    required this.fileNameMap,
    required this.destinationDirectory,
    required this.cacheDirectory,
    required this.saveToGallery,
    required this.androidSdkInt,
    this.senderAlias = '',
  });
}

/// Answers a pending [HttpServerPrepareUploadEvent].
///
/// When accepted, the server isolate receives all files on its own:
/// it resolves the save target for every upload, lets the Rust server write
/// the file and applies post-processing (timestamps, gallery). The main
/// isolate only observes [HttpServerFileUploadEvent],
/// [HttpServerFileUploadProgressEvent] and [HttpServerFileUploadResultEvent]
/// on the server event stream and may cancel the session via
/// [HttpServerCancelSessionTask].
class HttpServerPrepareUploadDecisionTask implements BaseHttpServerTask {
  /// The receive configuration including the accepted file IDs.
  /// `null` declines the request.
  final HttpServerReceiveConfig? config;
  final String sessionId;

  HttpServerPrepareUploadDecisionTask({
    required this.config,
    required this.sessionId,
  });
}

/// Cancels the active upload session, e.g. because the user aborted the
/// transfer on the receiving side. Uploads that are already in progress still
/// run to completion, but new upload requests are rejected and a new session
/// can be created. No [HttpServerSessionEndEvent] is emitted.
class HttpServerCancelSessionTask implements BaseHttpServerTask {
  final String sessionId;

  HttpServerCancelSessionTask({
    required this.sessionId,
  });
}

/// Answers a pending [HttpServerWebPrepareDownloadEvent].
class HttpServerPrepareDownloadDecisionTask implements BaseHttpServerTask {
  final String sessionId;

  /// `true` accepts the download request, `false` declines it.
  final bool accept;

  HttpServerPrepareDownloadDecisionTask({
    required this.sessionId,
    required this.accept,
  });
}

/// Answers a pending [HttpServerWebFileDownloadEvent] with the source the file
/// content should be read from: either a file [path] or a readable [fileDescriptor] (Android).
///
/// The file is read and streamed by the Rust server itself.
class HttpServerFileDownloadTargetTask implements BaseHttpServerTask {
  final String requestId;
  final String sessionId;
  final String fileId;
  final String? path;
  final int? fileDescriptor;

  HttpServerFileDownloadTargetTask({
    required this.requestId,
    required this.sessionId,
    required this.fileId,
    required this.path,
    required this.fileDescriptor,
  });
}

/// Fails a pending [HttpServerWebFileDownloadEvent], e.g. because no source
/// for the file content could be resolved. The download request fails with an
/// error response. Does nothing if the download was already answered with a
/// [HttpServerFileDownloadTargetTask].
class HttpServerFailFileDownloadTask implements BaseHttpServerTask {
  final String requestId;
  final String sessionId;
  final String fileId;

  HttpServerFailFileDownloadTask({
    required this.requestId,
    required this.sessionId,
    required this.fileId,
  });
}

/// A message sent from the server isolate to the main isolate.
sealed class HttpServerEvent {}

class HttpServerDirectoryUploadApprovalEvent extends HttpServerEvent {
  final String requestId;
  final String request;
  HttpServerDirectoryUploadApprovalEvent(this.requestId, this.request);
  @override
  String toString() => 'HttpServerDirectoryUploadApprovalEvent(redacted)';
}

class HttpServerDirectoryUploadApprovalAbortedEvent extends HttpServerEvent {
  final String requestId;
  HttpServerDirectoryUploadApprovalAbortedEvent(this.requestId);
}

class HttpServerDirectoryContentEvent extends HttpServerEvent {
  final String requestId;
  final String request;
  HttpServerDirectoryContentEvent(this.requestId, this.request);
  @override
  String toString() => 'HttpServerDirectoryContentEvent(redacted)';
}

class HttpServerWorkspaceManagementEvent extends HttpServerEvent {
  final String requestId;
  final String request;
  HttpServerWorkspaceManagementEvent(this.requestId, this.request);
  @override
  String toString() => 'HttpServerWorkspaceManagementEvent(redacted)';
}

/// The server has been started and is listening.
/// Always the first event emitted by a [HttpServerStartTask].
class HttpServerStartedEvent extends HttpServerEvent {
  final int port;
  HttpServerStartedEvent(this.port);
}

/// A device registered itself on this server.
///
/// On TLS, this event is only emitted when [RegisterDtoV2.fingerprint] matches
/// the fingerprint of the client certificate verified during the mTLS
/// handshake, so the fingerprint cannot be spoofed.
class HttpServerRegisterEvent extends HttpServerEvent {
  final String ip;
  final RegisterDtoV2 info;

  HttpServerRegisterEvent({
    required this.ip,
    required this.info,
  });
}

/// A sender requests to upload files.
/// Must be answered with a [HttpServerPrepareUploadDecisionTask].
class HttpServerPrepareUploadEvent extends HttpServerEvent {
  /// The session ID the upload session will have when the request is accepted.
  final String sessionId;
  final String ip;
  final RegisterDtoV2 info;

  /// The SHA-256 fingerprint (uppercase hex) of the sender's client
  /// certificate verified during the mTLS handshake. Unlike
  /// [RegisterDtoV2.fingerprint], this value cannot be spoofed.
  /// `null` when the server runs without TLS.
  final String? certFingerprint;

  final Map<String, FileDto> files;

  HttpServerPrepareUploadEvent({
    required this.sessionId,
    required this.ip,
    required this.info,
    required this.certFingerprint,
    required this.files,
  });
}

/// An accepted file started being uploaded.
/// The server isolate receives and saves the file on its own; the main
/// isolate only needs to update its view of the session.
class HttpServerFileUploadEvent extends HttpServerEvent {
  final String sessionId;
  final String fileId;
  final String? attemptId;
  final FileDto file;

  HttpServerFileUploadEvent({
    required this.sessionId,
    required this.fileId,
    this.attemptId,
    required this.file,
  });
}

/// The receive progress of a file as a fraction (0.0 to 1.0).
class HttpServerFileUploadProgressEvent extends HttpServerEvent {
  final String sessionId;
  final String fileId;
  final String? attemptId;
  final double progress;

  HttpServerFileUploadProgressEvent({
    required this.sessionId,
    required this.fileId,
    this.attemptId,
    required this.progress,
  });
}

/// Local integrity work; these bytes never count as transferred payload.
class HttpServerFileVerificationEvent extends HttpServerEvent {
  final String sessionId;
  final String fileId;
  final String attemptId;
  final int verifiedBytes;
  final int totalBytes;
  final bool verifying;

  HttpServerFileVerificationEvent({
    required this.sessionId,
    required this.fileId,
    required this.attemptId,
    required this.verifiedBytes,
    required this.totalBytes,
    required this.verifying,
  });
}

/// Self-contained successful-save metadata. It does not depend on the current
/// receive session and is never emitted for failed or merely queued writes.
class HttpServerReceiveReceipt {
  /// Child-generated identity, stable across retries of one accepted file and
  /// distinct when a peer reuses a file ID in another accepted session.
  final String receiptId;
  final String fileName;
  final FileType fileType;
  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;

  const HttpServerReceiveReceipt({
    required this.receiptId,
    required this.fileName,
    required this.fileType,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
  });
}

/// A file of the upload session has been received completely (or failed).
class HttpServerFileUploadResultEvent extends HttpServerEvent {
  final String sessionId;
  final String fileId;
  final String? attemptId;

  /// The path or content URI the file has been saved to.
  /// `null` when the file was saved to the gallery or on error.
  final String? path;

  /// Whether the file ended up in the OS gallery.
  final bool savedToGallery;

  /// `null` if the file has been saved successfully.
  final String? error;

  /// Present only after successful save and post-processing/publication.
  final HttpServerReceiveReceipt? receipt;

  HttpServerFileUploadResultEvent({
    required this.sessionId,
    required this.fileId,
    this.attemptId,
    required this.path,
    required this.savedToGallery,
    required this.error,
    this.receipt,
  });
}

/// An upload session ended.
class HttpServerSessionEndEvent extends HttpServerEvent {
  final String sessionId;
  final SessionEndReasonV2 reason;

  HttpServerSessionEndEvent({
    required this.sessionId,
    required this.reason,
  });
}

/// A prepare-upload request was aborted before a session was created,
/// e.g. the sender disconnected while the application was still deciding.
/// The [HttpServerPrepareUploadEvent] with the same [sessionId]
/// no longer needs to be answered.
class HttpServerPrepareUploadAbortedEvent extends HttpServerEvent {
  final String sessionId;

  HttpServerPrepareUploadAbortedEvent({required this.sessionId});
}

/// The remote device cancels a transfer this application is currently
/// *sending* to it. [sessionId] is the session ID issued by the remote device
/// during prepare-upload. The application must verify that [ip] matches the
/// target of the send session before cancelling it.
class HttpServerCancelReceivedEvent extends HttpServerEvent {
  final String ip;
  final String sessionId;

  HttpServerCancelReceivedEvent({
    required this.ip,
    required this.sessionId,
  });
}

/// A web client requests to download the shared files.
/// Must be answered with a [HttpServerPrepareDownloadDecisionTask].
class HttpServerWebPrepareDownloadEvent extends HttpServerEvent {
  final String ip;
  final String sessionId;
  final String? userAgent;

  HttpServerWebPrepareDownloadEvent({
    required this.ip,
    required this.sessionId,
    required this.userAgent,
  });
}

/// A pending browser approval ended before it was accepted.
class HttpServerWebPrepareDownloadAbortedEvent extends HttpServerEvent {
  final String sessionId;
  HttpServerWebPrepareDownloadAbortedEvent({required this.sessionId});
}

/// A web client downloads an offered file.
/// Must be answered with a [HttpServerFileDownloadTargetTask].
class HttpServerWebFileDownloadEvent extends HttpServerEvent {
  final String requestId;
  final String sessionId;
  final String fileId;
  final FileDto file;

  HttpServerWebFileDownloadEvent({
    required this.requestId,
    required this.sessionId,
    required this.fileId,
    required this.file,
  });
}

/// Another application instance requested the running application to show itself.
class HttpServerShowEvent extends HttpServerEvent {
  /// Command-line arguments forwarded by the other application instance.
  final List<String> args;

  HttpServerShowEvent({
    required this.args,
  });
}

/// The listening socket failed permanently, e.g. because the OS invalidated it
/// while the application was suspended (iOS reclaims the sockets of suspended
/// apps). The server has stopped itself; the application must restart it to
/// become reachable again.
class HttpServerListenerFailedEvent extends HttpServerEvent {
  /// Description of the failure.
  final String error;

  HttpServerListenerFailedEvent({
    required this.error,
  });
}

/// The approved destination could not acquire its native receive permission.
/// Kept separate from peer cancellation; presentation text belongs to the app.
class HttpServerReceiveDestinationErrorEvent extends HttpServerEvent {
  final String sessionId;
  HttpServerReceiveDestinationErrorEvent({required this.sessionId});
}

class _ReceiveSession {
  final HttpServerReceiveConfig config;
  final ReceiveScopeOwner scope = ReceiveScopeOwner();
  final void Function(HttpServerEvent)? emit;

  /// Directories already created inside the destination, shared across all
  /// files of the session.
  final Set<String> createdDirectories = {};

  /// Pending original-path names are reserved until this session is released.
  final ReceivePathReservations pathReservations = ReceivePathReservations();

  /// One queue per file ID, so that uploads of the same file do not overlap.
  ///
  /// A sender may upload the same file again after it was rejected because of
  /// a checksum mismatch. Both attempts write to the same [targets] entry.
  final Map<String, FutureQueue> uploads = {};

  /// The destination of each file of this session, by file ID.
  ///
  /// Remembered so that another attempt at the same file reuses its target instead
  /// of being saved next to it under a numbered name.
  final Map<String, FileSaveTarget> targets = {};
  final Map<String, String?> recoveryAttempts = {};

  /// Bounded by accepted file IDs; no retired-session registry is retained.
  final Map<String, String> receiptIds;

  _ReceiveSession(this.config, this.emit) : receiptIds = {for (final id in config.fileNameMap.keys) id: 'native:${const Uuid().v4()}'};
}

/// Holds the active receive session, set when a prepare-upload request is accepted.
final _receiveSessionProvider = Provider((ref) => _ReceiveSessionHolder());

class _ReceiveSessionHolder {
  String? pendingSessionId;
  Map<String, FileDto> pendingFiles = const {};
  _ReceiveSession? _session;
  void Function(HttpServerEvent)? emit;
  _ReceiveSession? get session => _session;
  set session(_ReceiveSession? value) {
    if (identical(_session, value)) return;
    final old = _session;
    _session = value;
    if (old != null) {
      unawaited(
        old.scope.retire().catchError((Object error, StackTrace stack) {
          _logger.warning('Receive directory scope release failed', error, stack);
        }),
      );
    }
  }

  final Map<String, SafReceiveAttempt> safAttempts = {};
}

Future<void> setupHttpServerIsolate(
  Stream<SendToIsolateData<IsolateTask<BaseHttpServerTask>>> receiveFromMain,
  void Function(IsolateTaskStreamResult<HttpServerEvent>) sendToMain,
  InitialData initialData, {

  /// Internal test seam: delays successful receipt delivery after the real save.
  /// Never used to postpone session release or the next prepare request.
  Future<void> Function(HttpServerReceiveReceipt receipt)? afterSave,

  /// Internal lifecycle test seam; production acquires only on iOS.
  Future<IosReceiveScopeLease?> Function(String path)? acquireReceiveScope,
}) async {
  await setupChildIsolateHelper(
    debugLabel: 'HttpServerIsolate',
    receiveFromMain: receiveFromMain,
    sendToMain: sendToMain,
    initialData: initialData,
    init: (ref) async {
      // Initialize the platform method channel so SAF (file creation) and the
      // gallery plugin work inside this isolate.
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        ref.read(syncProvider).rootIsolateToken as RootIsolateToken,
      );
    },
    handler: (ref, task) async {
      switch (task.data) {
        case HttpServerStartTask startTask:
          final syncState = ref.read(syncProvider);
          final service = ref.read(httpServerProvider);
          final Stream<RsServerEvent> events;
          try {
            events = await service.start(
              port: syncState.port,
              tls: syncState.protocol == ProtocolType.https
                  ? TlsConfig(
                      cert: syncState.securityContext.certificate,
                      privateKey: syncState.securityContext.privateKey,
                    )
                  : null,
              alias: syncState.alias,
              version: protocolVersion,
              deviceModel: syncState.deviceInfo.deviceModel,
              deviceType: syncState.deviceInfo.deviceType.toRust(),
              fingerprint: syncState.securityContext.certificateHash,
              pin: startTask.pin,
              verifyChecksums: startTask.verifyChecksums,
              web: startTask.web,
              showToken: startTask.showToken,
            );
          } catch (e) {
            // Starting failed (e.g. the port is already in use).
            // The error must be sendable across the isolate boundary.
            sendToMain(
              IsolateTaskStreamResult.error(
                id: task.id,
                error: e.humanErrorMessage,
              ),
            );
            return;
          }

          final int? boundPort;
          try {
            boundPort = await service.boundPortFor(events);
          } catch (error) {
            await events.listen((_) {}, onError: (Object _, StackTrace _) {}).cancel();
            try {
              await service.stop(expectedEvents: events);
            } catch (stopError) {
              _logger.warning('Failed to stop listener after port lookup failed', stopError);
            }
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: error.humanErrorMessage));
            return;
          }
          if (boundPort == null) {
            // A stop/replacement won while native startup or port lookup awaited.
            // Do not announce it, and detach this obsolete stream only.
            await events.listen((_) {}, onError: (Object _, StackTrace _) {}).cancel();
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
            return;
          }
          sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerStartedEvent(boundPort)));

          void emit(HttpServerEvent data) {
            sendToMain(
              IsolateTaskStreamResult.event(
                id: task.id,
                data: data,
              ),
            );
          }

          ref.read(_receiveSessionProvider).emit = emit;
          final sourceEndScopes = ReceiveSourceEndScopeHandler(
            reply: service.receiveSourceEndScopeResponder(events),
            isCurrent: () => service.ownsEvents(events),
          );
          final writes = DirectoryWriteProvider(reply: service.directoryWriteResponder(events), isCurrent: () => service.ownsEvents(events));
          final documents = DirectoryDocumentProvider(
            reply: service.directoryDocumentResponder(events),
            isCurrent: () => service.ownsEvents(events),
          );
          try {
            await for (final event in events) {
              // A stopped listener drains only its already-admitted workspace
              // write controls and denies stale source-end scope requests. Never route
              // ordinary old events into a new UI.
              if (!service.ownsEvents(events) &&
                  event is! RsServerEvent_DirectoryDocumentWrite &&
                  event is! RsServerEvent_DirectoryDocumentWriteCancelled &&
                  event is! RsServerEvent_DirectoryDocumentWriteDraining &&
                  event is! RsServerEvent_ReceiveSourceEndScope) {
                continue;
              }
              final holder = ref.read(_receiveSessionProvider);
              switch (event) {
                case RsServerEvent_ReceiveSourceEndScope(:final requestId, :final directory):
                  unawaited(
                    sourceEndScopes.handle(requestId, directory).catchError((Object error, StackTrace stack) {
                      _logger.warning('Receive source-end scope completion failed', error, stack);
                    }),
                  );
                case RsServerEvent_WebDownloadActivity(:final snapshot):
                  emit(HttpServerWebDownloadActivityEvent(snapshot));
                case RsServerEvent_DirectoryDocumentWrite(:final requestId, :final request):
                  unawaited(writes.handle(requestId, request));
                case RsServerEvent_DirectoryDocumentWriteCancelled(:final requestId):
                  unawaited(writes.cancelRequest(requestId));
                case RsServerEvent_DirectoryDocumentWriteDraining():
                  unawaited(writes.close());
                case RsServerEvent_DirectoryDocument(:final requestId, :final request):
                  unawaited(documents.handle(requestId, request));
                case RsServerEvent_DirectoryDocumentCancelled(:final requestId):
                  unawaited(documents.cancel(requestId));
                case RsServerEvent_DirectoryUploadApproval(:final requestId, :final request):
                  emit(HttpServerDirectoryUploadApprovalEvent(requestId, request));
                case RsServerEvent_DirectoryUploadApprovalAborted(:final requestId):
                  emit(HttpServerDirectoryUploadApprovalAbortedEvent(requestId));
                case RsServerEvent_DirectoryContent(:final requestId, :final request):
                  emit(HttpServerDirectoryContentEvent(requestId, request));
                case RsServerEvent_WorkspaceManagement(:final requestId, :final request):
                  emit(HttpServerWorkspaceManagementEvent(requestId, request));
                case RsServerEvent_Register(:final ip, :final info):
                  emit(HttpServerRegisterEvent(ip: ip, info: info));
                case RsServerEvent_PrepareUpload(:final sessionId, :final ip, :final info, :final certFingerprint, :final files):
                  // The Rust server is the authority on the single-session
                  // invariant: a new request means the old session is over.
                  holder.session = null;
                  holder.pendingSessionId = sessionId;
                  holder.pendingFiles = Map.unmodifiable(files);
                  emit(
                    HttpServerPrepareUploadEvent(
                      sessionId: sessionId,
                      ip: ip,
                      info: info,
                      certFingerprint: certFingerprint,
                      files: files,
                    ),
                  );
                case RsServerEvent_FileUpload(:final sessionId, :final fileId, :final file, :final durableRecovery, :final recoveryAttemptId):
                  final session = holder.session;
                  if (session == null || session.config.sessionId != sessionId || !session.config.fileNameMap.containsKey(fileId)) {
                    _logger.warning('Rejecting upload of file $fileId: no matching active session');
                    // Reject the upload (and any further ones) by cancelling the session.
                    unawaited(ref.read(httpServerProvider).cancelSession(sessionId: sessionId));
                    break;
                  }

                  if (durableRecovery == true && recoveryAttemptId == null) {
                    unawaited(service.failFileUpload(sessionId: sessionId, fileId: fileId, expectedAttemptId: recoveryAttemptId));
                    break;
                  }
                  final recoveryLookup = durableRecovery == true
                      ? service.receiveRecoveryLookup(events: events, sessionId: sessionId, fileId: fileId, attemptId: recoveryAttemptId!)
                      : null;
                  // Files may be uploaded concurrently, so the event loop must
                  // not block. Attempts of the same file are queued instead,
                  // see [_ReceiveSession.uploads].
                  final queue = session.uploads.putIfAbsent(
                    fileId,
                    () => FutureQueue(onError: (e, st) => _logger.severe('Unexpected error while receiving file $fileId', e, st)),
                  );
                  final releaseUse = session.scope.retain();
                  queue.add(() async {
                    try {
                      // A queued retry may outlive cancellation or replacement.
                      // Do not show it as a new transfer or open its old target.
                      if (!identical(holder.session, session)) return;
                      session.recoveryAttempts[fileId] = recoveryAttemptId;
                      emit(
                        HttpServerFileUploadEvent(
                          sessionId: sessionId,
                          fileId: fileId,
                          file: file,
                          attemptId: recoveryAttemptId,
                        ),
                      );

                      await _handleFileUpload(
                        ref: ref,
                        session: session,
                        sessionId: sessionId,
                        fileId: fileId,
                        file: file,
                        emit: emit,
                        recoveryAttemptId: recoveryAttemptId,
                        recoveryLookup: recoveryLookup,
                        afterSave: afterSave,
                      );
                    } finally {
                      releaseUse();
                    }
                  });
                case RsServerEvent_FileVerification(
                  :final sessionId,
                  :final fileId,
                  :final attemptId,
                  :final verifiedBytes,
                  :final totalBytes,
                  :final verifying,
                ):
                  final session = holder.session;
                  if (session != null && session.config.sessionId == sessionId && session.recoveryAttempts[fileId] == attemptId) {
                    emit(
                      HttpServerFileVerificationEvent(
                        sessionId: sessionId,
                        fileId: fileId,
                        attemptId: attemptId,
                        verifiedBytes: verifiedBytes.toInt(),
                        totalBytes: totalBytes.toInt(),
                        verifying: verifying,
                      ),
                    );
                  }
                case RsServerEvent_ReceiveCacheIdentity(:final sessionId, :final fileId, :final attemptId, :final transactionId, :final identityJson):
                  final session = holder.session;
                  final attempt = holder.safAttempts[transactionId];
                  unawaited(
                    answerSafCacheIdentity(
                      attempt: attempt,
                      sessionId: sessionId,
                      fileId: fileId,
                      transactionId: transactionId,
                      coreAttemptId: attemptId,
                      identityJson: identityJson,
                      isActive: () =>
                          service.ownsEvents(events) &&
                          session != null &&
                          identical(holder.session, session) &&
                          session.config.sessionId == sessionId &&
                          attempt != null &&
                          identical(session.targets[fileId]?.saf, attempt) &&
                          identical(holder.safAttempts[transactionId], attempt),
                      reply: (error, recovery) => service.respondReceiveCacheIdentity(
                        sessionId: sessionId,
                        fileId: fileId,
                        attemptId: attemptId,
                        transactionId: transactionId,
                        error: error,
                        recovery: recovery,
                      ),
                    ).catchError((Object error, StackTrace stack) {
                      _logger.fine('Receive identity result arrived after the responder ended', error, stack);
                    }),
                  );
                case RsServerEvent_ReceiveCacheRecovered(
                  :final sessionId,
                  :final fileId,
                  :final attemptId,
                  :final transactionId,
                  :final sourceTransactionId,
                  :final sourceLength,
                  :final sourceSha256,
                ):
                  final session = holder.session;
                  final attempt = holder.safAttempts[transactionId];
                  unawaited(
                    answerSafCacheRecovered(
                      attempt: attempt,
                      sessionId: sessionId,
                      fileId: fileId,
                      transactionId: transactionId,
                      coreAttemptId: attemptId,
                      sourceTransactionId: sourceTransactionId,
                      sourceLength: sourceLength.toInt(),
                      sourceSha256: sourceSha256,
                      isActive: () =>
                          service.ownsEvents(events) &&
                          session != null &&
                          identical(holder.session, session) &&
                          session.config.sessionId == sessionId &&
                          attempt != null &&
                          identical(session.targets[fileId]?.saf, attempt) &&
                          identical(holder.safAttempts[transactionId], attempt),
                      reply: (error) => service.respondReceiveCacheRecovered(
                        sessionId: sessionId,
                        fileId: fileId,
                        attemptId: attemptId,
                        transactionId: transactionId,
                        error: error,
                      ),
                    ).catchError((Object error, StackTrace stack) {
                      _logger.fine('Receive recovery result arrived after the responder ended', error, stack);
                    }),
                  );
                case RsServerEvent_PublishUpload(:final sessionId, :final fileId, :final attemptId, :final transactionId, :final size, :final sha256):
                  unawaited(
                    answerSafPublication(
                      attempt: holder.safAttempts[transactionId],
                      sessionId: sessionId,
                      fileId: fileId,
                      transactionId: transactionId,
                      coreAttemptId: attemptId,
                      size: size.toInt(),
                      sha256: sha256,
                      isActive: () => holder.session?.config.sessionId == sessionId,
                      reply: (error) => ref
                          .read(httpServerProvider)
                          .respondUploadPublication(
                            sessionId: sessionId,
                            fileId: fileId,
                            attemptId: attemptId,
                            transactionId: transactionId,
                            error: error,
                          ),
                    ).catchError((Object error, StackTrace stack) {
                      _logger.fine('Publication result arrived after the responder ended', error, stack);
                    }),
                  );
                case RsServerEvent_UploadCacheReleased(:final transactionId, :final published):
                  // Release means handles closed, not proof that a provider did
                  // not finish publishing after cancellation. No guessed deletion.
                  _logger.fine('Cache handles released: $transactionId; acknowledged publication: $published');
                case RsServerEvent_SessionEnd(:final sessionId, :final reason):
                  if (holder.session?.config.sessionId == sessionId) {
                    holder.session = null;
                  }
                  if (holder.pendingSessionId == sessionId) {
                    holder.pendingSessionId = null;
                    holder.pendingFiles = const {};
                  }
                  emit(
                    HttpServerSessionEndEvent(
                      sessionId: sessionId,
                      reason: reason,
                    ),
                  );
                case RsServerEvent_PrepareUploadAborted(:final sessionId):
                  if (holder.pendingSessionId == sessionId) {
                    holder.pendingSessionId = null;
                    holder.pendingFiles = const {};
                  }
                  if (holder.session?.config.sessionId == sessionId) holder.session = null;
                  emit(
                    HttpServerPrepareUploadAbortedEvent(
                      sessionId: sessionId,
                    ),
                  );
                case RsServerEvent_CancelReceived(:final ip, :final sessionId):
                  emit(
                    HttpServerCancelReceivedEvent(
                      ip: ip,
                      sessionId: sessionId,
                    ),
                  );
                case RsServerEvent_WebPrepareDownload(:final ip, :final sessionId, :final userAgent):
                  emit(
                    HttpServerWebPrepareDownloadEvent(
                      ip: ip,
                      sessionId: sessionId,
                      userAgent: userAgent,
                    ),
                  );
                case RsServerEvent_WebPrepareDownloadAborted(:final sessionId):
                  emit(HttpServerWebPrepareDownloadAbortedEvent(sessionId: sessionId));
                case RsServerEvent_WebFileDownload(:final requestId, :final sessionId, :final fileId, :final file):
                  emit(
                    HttpServerWebFileDownloadEvent(
                      requestId: requestId,
                      sessionId: sessionId,
                      fileId: fileId,
                      file: file,
                    ),
                  );
                case RsServerEvent_Show(:final args):
                  emit(HttpServerShowEvent(args: args));
                case RsServerEvent_ListenerFailed(:final error):
                  ref.read(_receiveSessionProvider)
                    ..session = null
                    ..pendingSessionId = null
                    ..pendingFiles = const {};
                  emit(HttpServerListenerFailedEvent(error: error));
              }
            }
          } finally {
            unawaited(writes.close());
            unawaited(documents.close());
            if (service.ownsEvents(events)) {
              ref.read(_receiveSessionProvider)
                ..session = null
                ..pendingSessionId = null
                ..pendingFiles = const {};
            }
            sendToMain(
              IsolateTaskStreamResult.done(
                id: task.id,
              ),
            );
          }
          return;
        case HttpServerWebDownloadSnapshotTask():
          try {
            final result = await ref.read(httpServerProvider).webDownloadActivity();
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(result)));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Web download snapshot unavailable'));
          }
          return;
        case HttpServerCancelWebDownloadTask update:
          try {
            final result = await ref.read(httpServerProvider).cancelWebDownload(update.requestId);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(result.toString())));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Web download cancellation failed'));
          }
          return;
        case HttpServerDirectoryUploadApprovalTask update:
          try {
            final result = await ref.read(httpServerProvider).directoryUploadApproval(update.requestId, update.accept);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(result.toString())));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Directory upload approval expired'));
          }
          return;
        case HttpServerDirectoryContentTask update:
          try {
            await ref.read(httpServerProvider).directoryContent(update.requestId, update.response);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult('ok')));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Workspace content acknowledgement expired'));
          }
          return;
        case HttpServerWorkspaceManagementTask update:
          try {
            final result = await ref.read(httpServerProvider).workspaceManagement(update.requestId, update.response);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(result)));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Workspace management acknowledgement failed'));
          }
          return;
        case HttpServerIntegrationTask update:
          try {
            final service = ref.read(httpServerProvider);
            final result = update.consoleRequest != null
                ? await service.integrationApiRequest(update.consoleRequest!)
                : update.configuration == null
                ? await service.integrationApiSnapshot()
                : await service.configureIntegrationApi(update.configuration!);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(result)));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            // Never expose persistence JSON or credential material in isolate errors.
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'API service operation failed'));
          }
          return;
        case HttpServerCaptureWorkspaceSourcesTask capture:
          try {
            final result = await ref
                .read(httpServerProvider)
                .captureWorkspaceSources(capture.workspaceId, capture.generation, capture.files, capture.destination);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerDirectoryCatalogResult(result)));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Workspace sources changed or storage unavailable'));
          }
          return;
        case HttpServerDirectoryCatalogTask update:
          try {
            final acknowledgement = await ref.read(httpServerProvider).configureDirectoryWorkspaces(update.config);
            sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerDirectoryCatalogResult(acknowledgement)));
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (e) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: e.humanErrorMessage));
          }
          return;
        case HttpServerSetWorkspaceTask update:
          try {
            await ref
                .read(httpServerProvider)
                .setWebWorkspace(enabled: update.enabled, files: update.files, pin: update.pin, allowUpload: update.allowUpload);
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Temporary share update failed'));
          }
          return;
        case HttpServerPatchWorkspaceTask patch:
          try {
            await ref.read(httpServerProvider).patchWebWorkspace(files: patch.files, removeFileIds: patch.removeFileIds);
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (_) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Temporary file update failed'));
          }
          return;
        case HttpServerUpdateWorkspaceTask update:
          try {
            await ref.read(httpServerProvider).updateWebWorkspace(files: update.files, allowUpload: update.allowUpload);
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (e) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: e.humanErrorMessage));
          }
          return;
        case HttpServerStopTask stop:
          ref.read(_receiveSessionProvider)
            ..session = null
            ..pendingSessionId = null
            ..pendingFiles = const {};
          try {
            final service = ref.read(httpServerProvider);
            if (stop.captureActivity) {
              final snapshot = await service.stopWithActivity();
              sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpServerIntegrationResult(snapshot ?? '')));
            } else {
              await service.stop();
            }
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (error) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: error.humanErrorMessage));
          }
          return;
        case HttpServerPrepareUploadDecisionTask decisionTask:
          final holder = ref.read(_receiveSessionProvider);
          if (holder.pendingSessionId != decisionTask.sessionId) return;
          final config = decisionTask.config;
          if (config != null && config.sessionId != decisionTask.sessionId) return;
          final offered = holder.pendingFiles;
          holder.pendingFiles = const {};
          holder.pendingSessionId = null;
          // Install before responding so an immediate upload finds its target.
          final accepted = config == null || config.fileNameMap.isEmpty ? null : _ReceiveSession(config, holder.emit);
          holder.session = accepted;
          final releasePreparation = accepted?.scope.retain();
          try {
            if (accepted != null && (Platform.isIOS || acquireReceiveScope != null)) {
              try {
                await accepted.scope.acquire(() => (acquireReceiveScope ?? acquireIosReceiveScope)(accepted.config.destinationDirectory));
              } catch (error, stack) {
                if (identical(holder.session, accepted)) {
                  accepted.emit?.call(HttpServerReceiveDestinationErrorEvent(sessionId: decisionTask.sessionId));
                  holder.session = null;
                  await ref.read(httpServerProvider).respondPrepareUpload(sessionId: decisionTask.sessionId, acceptedFileIds: null);
                  _logger.warning('Approved receive directory is unavailable', error, stack);
                }
                return;
              }
            }
            if (!identical(holder.session, accepted)) return;
            final durableIds = config == null
                ? null
                : await probeDurableReceiveFileIds(
                    approvedDirectory: config.destinationDirectory,
                    candidates: durableReceiveFileIds(
                      destinationDirectory: config.destinationDirectory,
                      cacheDirectory: config.cacheDirectory,
                      saveToGallery: config.saveToGallery,
                      androidSdkInt: config.androidSdkInt,
                      acceptedIds: config.fileNameMap.keys,
                      sizes: {for (final entry in offered.entries) entry.key: entry.value.size.toInt()},
                    ),
                    approvedNames: config.fileNameMap,
                    probe: ref.read(httpServerProvider).supportsReceiveRecoveryTarget,
                    isActive: () => identical(holder.session, accepted),
                  );
            if (!identical(holder.session, accepted)) return;
            final safResumableIds = config == null
                ? const <String>[]
                : await probeSafResumableReceiveFileIds(
                    destinationDirectory: config.destinationDirectory,
                    cacheDirectory: config.cacheDirectory,
                    sessionId: decisionTask.sessionId,
                    saveToGallery: config.saveToGallery,
                    androidSdkInt: config.androidSdkInt,
                    acceptedIds: config.fileNameMap.keys,
                    sizes: {for (final entry in offered.entries) entry.key: entry.value.size.toInt()},
                    approvedNames: config.fileNameMap,
                    isActive: () => identical(holder.session, accepted),
                    probe: probeReceiveDescriptorPair,
                  );
            if (!identical(holder.session, accepted)) return;
            final applied = await ref
                .read(httpServerProvider)
                .respondPrepareUpload(
                  sessionId: decisionTask.sessionId,
                  acceptedFileIds: config?.fileNameMap.keys.toList(),
                  resumableFileIds: config == null
                      ? null
                      : [
                          ...resumableReceiveFileIds(
                            destinationDirectory: config.destinationDirectory,
                            saveToGallery: config.saveToGallery,
                            androidSdkInt: config.androidSdkInt,
                            acceptedIds: config.fileNameMap.keys,
                            sizes: {for (final entry in offered.entries) entry.key: entry.value.size.toInt()},
                          ),
                          ...safResumableIds,
                        ],
                  durableFileIds: durableIds,
                );
            if (!applied && identical(holder.session, accepted)) holder.session = null;
          } catch (error) {
            if (identical(holder.session, accepted)) holder.session = null;
            rethrow;
          } finally {
            releasePreparation?.call();
          }
          return;
        case HttpServerCancelSessionTask cancelTask:
          final holder = ref.read(_receiveSessionProvider);
          if (holder.session?.config.sessionId == cancelTask.sessionId) {
            holder.session = null;
          }
          await ref.read(httpServerProvider).cancelSession(sessionId: cancelTask.sessionId);
          return;
        case HttpServerPrepareDownloadDecisionTask decisionTask:
          try {
            await ref.read(httpServerProvider).respondPrepareDownload(sessionId: decisionTask.sessionId, accept: decisionTask.accept);
            sendToMain(IsolateTaskStreamResult.done(id: task.id));
          } catch (e) {
            sendToMain(IsolateTaskStreamResult.error(id: task.id, error: e.humanErrorMessage));
          }
          return;
        case HttpServerFileDownloadTargetTask targetTask:
          await ref
              .read(httpServerProvider)
              .respondFileDownload(
                requestId: targetTask.requestId,
                sessionId: targetTask.sessionId,
                fileId: targetTask.fileId,
                path: targetTask.path,
                fileDescriptor: targetTask.fileDescriptor,
              );
          return;
        case HttpServerFailFileDownloadTask failTask:
          await ref
              .read(httpServerProvider)
              .failFileDownload(
                requestId: failTask.requestId,
                sessionId: failTask.sessionId,
                fileId: failTask.fileId,
              );
          return;
      }
    },
  );
}

/// Avoid opening/truncating destinations for queued attempts whose session ended.
/// A provider may finish opening a descriptor after cancellation; such a descriptor
/// remains Dart-owned and must be released without deleting the provider document.
Future<FileSaveTarget?> prepareReceiveTargetIfActive({
  required bool Function() isActive,
  required Future<FileSaveTarget> Function() prepare,
}) async {
  if (!isActive()) return null;
  final FileSaveTarget target;
  try {
    target = await prepare();
  } catch (_) {
    // Cancellation can win while provider/filesystem work is pending. A late
    // preparation error belongs to the old owner, not its replacement session.
    if (!isActive()) return null;
    rethrow;
  }
  if (isActive()) return target;
  if (target.saf != null) {
    await target.saf!.finish();
    return null;
  }
  final descriptor = target.fileDescriptor;
  if (descriptor != null) {
    // This existing bridge operation only closes the owned descriptor. Passing
    // no path makes the ownership boundary explicit and never deletes a file.
    await discardDownloadSource(path: null, fileDescriptor: descriptor);
  }
  return null;
}

/// Receives a single file without involving the main isolate:
/// resolves the save target, lets the Rust server write the file and applies
/// the post-processing (timestamps, gallery).
///
/// [emit]s [HttpServerFileUploadProgressEvent]s while the file is being
/// received, followed by a final [HttpServerFileUploadResultEvent].
Future<void> _handleFileUpload({
  required Ref ref,
  required _ReceiveSession session,
  required String sessionId,
  required String fileId,
  required FileDto file,
  required void Function(HttpServerEvent event) emit,
  Future<void> Function(HttpServerReceiveReceipt receipt)? afterSave,
  String? recoveryAttemptId,
  ReceiveRecoveryLookup? recoveryLookup,
}) async {
  final config = session.config;
  final desiredName = config.fileNameMap[fileId]!;
  final dartFile = file.toDart();
  final isImage = dartFile.fileType == FileType.image;
  final shouldSaveToGallery = config.saveToGallery && (isImage || dartFile.fileType == FileType.video);

  void emitFailed(Object e) {
    emit(
      HttpServerFileUploadResultEvent(
        sessionId: sessionId,
        fileId: fileId,
        attemptId: recoveryAttemptId,
        path: null,
        savedToGallery: false,
        error: e.humanErrorMessage,
      ),
    );
  }

  _logger.info('Saving ${dartFile.fileName}');

  final FileSaveTarget target;
  try {
    // A previous attempt at this file already picked a destination, which this
    // attempt reuses its target instead of creating a numbered version.
    final previous = session.targets[fileId];
    bool isActive() => identical(ref.read(_receiveSessionProvider).session, session) && session.recoveryAttempts[fileId] == recoveryAttemptId;
    final prepared = await prepareReceiveTargetIfActive(
      isActive: isActive,
      prepare: () => previous != null && recoveryLookup == null
          ? reopenFileSaveTarget(previous)
          : prepareFileSaveTarget(
              destinationDirectory: config.destinationDirectory,
              cacheDirectory: config.cacheDirectory,
              fileName: desiredName,
              saveToGallery: shouldSaveToGallery,
              isImage: isImage,
              createdDirectories: session.createdDirectories,
              reservations: session.pathReservations,
              androidSdkInt: config.androidSdkInt,
              receiveSessionId: sessionId,
              receiveFileId: fileId,
              recoveryLookup: recoveryLookup,
              previousPath: previous?.path,
              isActive: isActive,
            ),
    );
    if (prepared == null) return;
    target = prepared;
    session.targets[fileId] = target;
    if (target.saf != null) ref.read(_receiveSessionProvider).safAttempts[target.saf!.transactionId] = target.saf!;
  } catch (e, st) {
    _logger.severe('Failed to prepare save target', e, st);

    // The Rust server is still waiting for the target; failing it ends the
    // sender's request which would otherwise hang forever.
    try {
      await ref.read(httpServerProvider).failFileUpload(sessionId: sessionId, fileId: fileId, expectedAttemptId: recoveryAttemptId);
    } catch (e) {
      _logger.warning('Could not fail the pending file upload', e);
    }

    emitFailed(e);
    return;
  }

  try {
    // The Rust server writes the file and reports the progress.
    final service = ref.read(httpServerProvider);
    final progressStream = target.saf != null
        ? service.respondCachedFileUpload(attempt: target.saf!, fileSize: dartFile.size)
        : service.respondFileUpload(
            sessionId: sessionId,
            fileId: fileId,
            path: target.path,
            fileDescriptor: target.fileDescriptor,
            fileSize: dartFile.size,
            expectedAttemptId: recoveryAttemptId,
          );
    await drainReceiveProgress(progressStream, (progress) {
      emit(
        HttpServerFileUploadProgressEvent(
          sessionId: sessionId,
          fileId: fileId,
          attemptId: recoveryAttemptId,
          progress: progress,
        ),
      );
    });
  } catch (e, st) {
    // Cached targets release only after Rust closes both descriptors. A late
    // successful provider publication is retained even when its HTTP ack was lost.
    _logger.severe('Failed to save file', e, st);
    emitFailed(e);
    return;
  } finally {
    final attempt = target.saf;
    if (attempt != null) {
      // The Rust result/progress stream has drained, so no writer owns these
      // handles. A late native publication finishes before cleanup is allowed.
      try {
        await attempt.finish();
      } catch (error, stack) {
        _logger.warning('SAF cleanup retained for reconciliation', error, stack);
      }
      ref.read(_receiveSessionProvider).safAttempts.remove(attempt.transactionId);
    }
  }

  try {
    if (target.saf != null && target.saf!.publishedUri == null) throw StateError('Missing published provider receipt');
    String? filePath;
    bool savedToGallery = false;
    if (shouldSaveToGallery) {
      (savedToGallery, filePath) = await saveCachedFileToGallery(
        cachedPath: target.displayPath,
        destinationDirectory: config.destinationDirectory,
        fileName: desiredName,
        isImage: isImage,
        createdDirectories: session.createdDirectories,
      );
    } else {
      filePath = target.displayPath;
    }

    final receipt = HttpServerReceiveReceipt(
      receiptId: target.recovery == null ? session.receiptIds[fileId]! : 'native-durable:${target.recovery!.receiptId}',
      fileName: desiredName,
      fileType: dartFile.fileType,
      fileSize: dartFile.size,
      senderAlias: config.senderAlias,
      timestamp: target.recovery?.completedAt ?? DateTime.now().toUtc(),
    );
    // Capture success time before a delayed delivery; a history-clear watermark
    // must compare completion time, not when the main isolate sees the result.
    await afterSave?.call(receipt);
    _logger.info('Saved ${dartFile.fileName}.');
    emit(
      HttpServerFileUploadResultEvent(
        sessionId: sessionId,
        fileId: fileId,
        attemptId: recoveryAttemptId,
        path: filePath,
        savedToGallery: savedToGallery,
        error: null,
        receipt: receipt,
      ),
    );
  } catch (e, st) {
    _logger.severe('Failed to post-process file', e, st);
    emitFailed(e);
  }
}
