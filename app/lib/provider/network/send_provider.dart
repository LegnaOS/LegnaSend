import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/send_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_app/util/ui/transfer_route.dart';
import 'package:localsend_app/util/upload_recovery_strings.dart';
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localsend_isolates/rust/api/http.dart' as rust_http;
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/util/file_hash.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uri_content/uri_content.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _logger = Logger('Send');

/// Route errors carry local stable codes; ordinary socket/peer failures keep
/// their original diagnostic and are not described as VPN-routing failures.
String _sendErrorMessage(Object error) {
  final message = error.humanErrorMessage;
  final match = RegExp(
    r'(?:^|field0: |Bad state: )(local-route-(?:invalid|unavailable)|selected-local-route-unavailable)(?=:|$)',
  ).firstMatch(message);
  if (match == null) return message;
  final copy = SendRouteStrings(LocaleSettings.currentLocale);
  return match[1] == 'local-route-invalid' ? copy.localRouteInvalid : copy.localRouteUnavailable;
}

/// This provider manages sending files to other devices.
///
/// In contrast to [serverProvider], this provider does not manage a server.
/// Instead, it only does HTTP requests to other servers.
final sendProvider = NotifierProvider<SendNotifier, Map<String, SendSessionState>>((ref) {
  return SendNotifier();
});

class SendNotifier extends Notifier<Map<String, SendSessionState>> {
  SendNotifier({this.uploadFiles, this.cancelUpload, this.ackSourceEnd});

  final IsolateHttpUploadActionResult Function(IsolateHttpUploadFilesAction action)? uploadFiles;
  final void Function(int taskId)? cancelUpload;
  final void Function(IsolateHttpSourceEndAckAction action)? ackSourceEnd;

  IsolateHttpUploadActionResult _upload(IsolateHttpUploadFilesAction action) =>
      uploadFiles?.call(action) ?? ref.redux(parentIsolateProvider).dispatchTakeResult(action);
  void _cancelUpload(int taskId) {
    if (cancelUpload != null) {
      cancelUpload!(taskId);
      return;
    }
    ref.redux(parentIsolateProvider).dispatch(IsolateHttpUploadCancelAction(taskId: taskId));
  }

  final _routes = <String, TransferRoute>{};
  final _attempts = <String, Object>{};
  final _presentationAttempts = <String, Object>{};

  /// Opaque attempt identity for confirmations spanning asynchronous UI work.
  // Keep identity through cancellation while its terminal result still exists.
  Object? sessionAttemptIdentity(String sessionId) => _presentationAttempts[sessionId];
  bool _disposed = false;
  bool _currentAttempt(String id, Object attempt) => !_disposed && identical(_attempts[id], attempt);
  final _retainedSessions = <String>{};
  final _cancelRequests = <String, Future<void>>{};

  /// Cancel tokens of the running checksum calculations.
  /// Session ID -> Cancel token
  final _hashCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  /// Cancel tokens of the running prepare-upload requests.
  /// Cancelling aborts the request, which tells the receiver that the sender
  /// is no longer waiting for a decision.
  /// Session ID -> Cancel token
  final _prepareUploadCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  @override
  Map<String, SendSessionState> init() {
    return {};
  }

  /// The debug observer stringifies the state on every change,
  /// so large file maps must be summarized to keep transfers responsive in debug mode.
  @override
  String describeState(Map<String, SendSessionState> state) {
    if (state.values.every((session) => session.files.length <= 10)) {
      return state.toString();
    }
    return state.map((sessionId, session) {
      if (session.files.length <= 10) {
        return MapEntry(sessionId, session.toString());
      }
      return MapEntry(
        sessionId,
        session.copyWith(files: {}).toString().replaceFirst('files: {}', 'files: <${session.files.length} files>'),
      );
    }).toString();
  }

  /// Starts a session.
  /// If [background] is true, then the session closes itself on success and no pages will be open
  /// If [background] is false, then this method will open pages by itself and waits for user input to close the session.
  Future<void> startSession({
    required Device target,
    required List<CrossFile> files,
    required bool background,
    String? requestedSessionId,
    bool retainSession = false,
    LocalSendRoute? localRoute,
    List<String>? resumeKeys,
  }) async {
    final sessionId = requestedSessionId ?? _uuid.v4();
    if (_disposed) return;
    final previous = state[sessionId];
    if (previous != null && {SessionStatus.waiting, SessionStatus.sending}.contains(previous.status)) {
      throw StateError('Send session is already active');
    }
    final attempt = Object();
    _attempts[sessionId] = attempt;
    _presentationAttempts[sessionId] = attempt;
    if (retainSession) _retainedSessions.add(sessionId);
    try {
      await _startSession(
        target: target,
        files: files,
        background: background,
        sessionId: sessionId,
        attempt: attempt,
        localRoute: localRoute,
        resumeKeys: resumeKeys,
      );
    } finally {
      if (_currentAttempt(sessionId, attempt)) _retainedSessions.remove(sessionId);
    }
  }

  Future<void> _startSession({
    required Device target,
    required List<CrossFile> files,
    required bool background,
    required String sessionId,
    required Object attempt,
    LocalSendRoute? localRoute,
    List<String>? resumeKeys,
  }) async {
    final createChecksums = ref.read(settingsProvider).createChecksums;

    // The ids are assigned upfront, so the checksums calculated below
    // can be mapped back to the corresponding file.
    if (resumeKeys != null && resumeKeys.length != files.length) throw ArgumentError('Recovery key count mismatch');
    final selectedFiles = [for (var i = 0; i < files.length; i++) (id: _uuid.v4(), file: files[i], resumeKey: resumeKeys?[i])];

    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => SendSessionState(
        sessionId: sessionId,
        remoteSessionId: null,
        background: background,
        status: SessionStatus.waiting,
        target: target,
        localRoute: localRoute,
        files: {
          for (final (:id, :file, :resumeKey) in selectedFiles)
            id: SendingFile(
              file: FileDto(
                id: id,
                fileName: file.name,
                size: file.size,
                fileType: file.fileType,
                hash: null,
                // calculated below
                preview: files.length == 1 && files.first.fileType == FileType.text && files.first.bytes != null
                    ? utf8.decode(files.first.bytes!) // send simple message by embedding it into the preview
                    : null,
                metadata: file.lastModified != null || file.lastAccessed != null
                    ? FileMetadata(
                        lastModified: file.lastModified,
                        lastAccessed: file.lastAccessed,
                      )
                    : null,
              ),
              token: null,
              resumeKey: resumeKey,
              thumbnail: file.thumbnail,
              asset: file.asset,
              path: file.path,
              bytes: file.bytes,
              errorMessage: null,
            ),
        },
        // Skipping the checksums marks all files as hashed, so the UI does not
        // show the checksum progress.
        hashedFileCount: createChecksums ? 0 : selectedFiles.length,
        startTime: null,
        endTime: null,
        sendingTasks: [],
        errorMessage: null,
      ),
    );

    final transfer = ref.notifier(fileTransferProvider);
    // A caller may deliberately reuse a terminal history ID for a new attempt.
    // Old file IDs/results must not poison the new attempt's completion status.
    transfer.removeSession(sessionId);
    transfer.setStatuses(sessionId: sessionId, statuses: {for (final f in selectedFiles) f.id: FileStatus.queue});

    if (!background) {
      // ignore: use_build_context_synchronously
      final route = _routes[sessionId] = TransferRoute(Routerino.context);
      unawaited(route.show((_) => SendPage(showAppBar: true, closeSessionOnClose: false, sessionId: sessionId)));
    }

    if (localRoute != null && !localSendRouteMatchesHost(localRoute, target.ip)) {
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.finishedWithErrors,
          errorMessage: SendRouteStrings(LocaleSettings.currentLocale).addressFamilyMismatch,
          endTime: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }

    // Construct only after the visible session exists: binding can fail before
    // any request is sent, and that failure must remain an observable terminal
    // result. Never retry through an unbound client.
    final rust_http.RsHttpClient client;
    try {
      client = ref.read(httpProvider).pinnedTo(target.fingerprint, localRoute: localRoute);
    } catch (error) {
      if (_currentAttempt(sessionId, attempt)) {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: SessionStatus.finishedWithErrors,
            errorMessage: _sendErrorMessage(error),
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      return;
    }

    // Calculate the checksums which are part of the request.
    // The files are read and hashed in Rust, one file after another.
    final hashes = <String, String>{};
    if (createChecksums) {
      final hashCancelToken = rust_cancel.createCancellationToken();
      _hashCancelTokens[sessionId] = hashCancelToken;
      try {
        for (final (:id, :file, resumeKey: _) in selectedFiles) {
          try {
            hashes[id] = await calculateFileHash(
              path: file.path,
              bytes: file.bytes,
              cancelToken: hashCancelToken,
              onProgress: (bytes) {
                if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) {
                  // session has been canceled while calculating the checksums
                  return;
                }
                ref
                    .notifier(fileTransferProvider)
                    .setProgress(
                      sessionId: sessionId,
                      fileId: id,
                      progress: file.size == 0 ? 1 : (bytes / file.size).clamp(0, 1),
                    );
              },
            );
          } catch (e) {
            if (_currentAttempt(sessionId, attempt) && state[sessionId] != null) {
              // Sending the checksum is optional, so a file that cannot be read
              // here still gets a chance to be sent.
              // Errors caused by the cancellation are not logged.
              _logger.warning('Could not calculate the checksum of ${file.name}', e);
            }
          }

          if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) {
            // session has been canceled while calculating the checksums
            return;
          }

          // Also set for files whose hashing failed, so the progress bar stays
          // consistent with the files that are left.
          ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: id, progress: 1);
          state = state.updateSession(
            sessionId: sessionId,
            state: (s) => s?.copyWith(hashedFileCount: s.hashedFileCount + 1),
          );
        }
      } finally {
        if (identical(_hashCancelTokens[sessionId], hashCancelToken)) _hashCancelTokens.remove(sessionId);
      }
    }

    final hashedState = state[sessionId];
    if (!_currentAttempt(sessionId, attempt) || hashedState == null || hashedState.status != SessionStatus.waiting) {
      // session has been canceled while calculating the checksums
      return;
    }

    final requestState = hashedState.copyWith(
      files: hashedState.files.map(
        (id, sendingFile) => MapEntry(id, sendingFile.copyWith(file: sendingFile.file.withHash(hashes[id]))),
      ),
    );
    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => requestState,
    );

    final originDevice = ref.read(deviceFullInfoProvider);
    final requestDto = rust_model.PrepareUploadRequestDto(
      info: rust_model.RegisterDto(
        alias: originDevice.alias,
        version: originDevice.version,
        deviceModel: originDevice.deviceModel,
        deviceType: originDevice.deviceType.toRust(),
        token: originDevice.fingerprint,
        port: originDevice.port,
        protocol: originDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        hasWebInterface: originDevice.download,
      ),
      files: {
        for (final entry in requestState.files.entries) entry.key: entry.value.file.toRust(),
      },
    );

    rust_http.PrepareUploadResult? response;
    bool invalidPin;
    bool pinFirstAttempt = true;
    String? pin;
    final prepareUploadCancelToken = rust_cancel.createCancellationToken();
    _prepareUploadCancelTokens[sessionId] = prepareUploadCancelToken;
    try {
      do {
        invalidPin = false;
        if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) return;
        try {
          response = await client.prepareUpload(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            payload: requestDto,
            // The peer is already verified during the TLS handshake by the
            // fingerprint the client is pinned to.
            publicKey: null,
            pin: pin,
            cancelToken: prepareUploadCancelToken,
          );
        } on rust_http.RsHttpClientError_StatusCode catch (e) {
          if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) return;
          switch (e.status) {
            case 401:
              invalidPin = true;

              // wait until animation is finished
              await sleepAsync(500);
              if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) return;

              pin = await showDialog<String>(
                context: Routerino.context, // ignore: use_build_context_synchronously
                builder: (_) => PinDialog(
                  obscureText: true,
                  showInvalidPin: !pinFirstAttempt,
                ),
              );

              pinFirstAttempt = false;
              if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) return;

              if (pin == null) {
                state = state.updateSession(
                  sessionId: sessionId,
                  state: (s) => s?.copyWith(
                    status: SessionStatus.canceledBySender,
                  ),
                );
                return;
              }
              break;
            case 403:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.declined,
                ),
              );
              return;
            case 409:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.recipientBusy,
                ),
              );
              return;
            case 429:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.tooManyAttempts,
                ),
              );
              return;
            default:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.finishedWithErrors,
                  errorMessage: _sendErrorMessage(e),
                ),
              );
              return;
          }
        } catch (e) {
          if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) return;
          state = state.updateSession(
            sessionId: sessionId,
            state: (s) => s?.copyWith(
              status: SessionStatus.finishedWithErrors,
              errorMessage: _sendErrorMessage(e),
            ),
          );
          return;
        }
      } while (invalidPin);
    } finally {
      if (identical(_prepareUploadCancelTokens[sessionId], prepareUploadCancelToken)) _prepareUploadCancelTokens.remove(sessionId);
    }

    if (!_currentAttempt(sessionId, attempt) || state[sessionId]?.status != SessionStatus.waiting) {
      // A peer may approve just as cancellation wins locally. Release its new
      // session instead of reviving a canceled queue entry or leaking its slot.
      await _notifyReceiverCanceled(requestState.copyWith(remoteSessionId: response?.response?.sessionId));
      return;
    }

    if (response == null) {
      return;
    }

    final Map<String, String> fileMap;
    if (response.statusCode == 204) {
      // Nothing selected
      // Interpret this as "Read and close"
      fileMap = {};
    } else {
      try {
        fileMap = response.response!.files;
        final remoteSessionId = response.response!.sessionId;
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            remoteSessionId: remoteSessionId,
          ),
        );
      } catch (e) {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: SessionStatus.finishedWithErrors,
            errorMessage: _sendErrorMessage(e),
          ),
        );
        return;
      }
    }

    if (fileMap.isEmpty) {
      // receiver has nothing selected
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.finished,
        ),
      );

      _routes.remove(sessionId)?.close();

      if (!_retainedSessions.contains(sessionId)) closeSession(sessionId);
      return;
    }

    final sendingFiles = {
      for (final file in requestState.files.values)
        file.file.id: fileMap.containsKey(file.file.id) ? file.copyWith(token: fileMap[file.file.id]) : file,
    };

    // Recreate the transfer state: the hash progress is no longer needed and must not be
    // mistaken for upload progress, which starts at zero for every file.
    final transferNotifier = ref.notifier(fileTransferProvider);
    transferNotifier.removeSession(sessionId);
    transferNotifier.setStatuses(
      sessionId: sessionId,
      statuses: {for (final file in sendingFiles.values) file.file.id: file.token != null ? FileStatus.queue : FileStatus.skipped},
    );

    final route = _routes[sessionId];
    if (route?.isOpen == true) {
      unawaited(
        route!.show((_) => ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: sessionId)).then((_) {
          if (identical(_routes[sessionId], route)) _routes.remove(sessionId);
          if (_currentAttempt(sessionId, attempt)) setBackground(sessionId, true);
        }),
      );
    }

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.sending,
        files: sendingFiles,
      ),
    );

    // Keep the process alive for the whole transfer. Started here, while the app is still in the
    // foreground, because Android 12+ rejects starting a foreground service from the background.
    TransferNotification.start(sessionId: sessionId, receiving: false);

    await _sendLoop(sessionId, sendingFiles, attempt);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(String sessionId) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final session = state[sessionId];
    if (session == null) {
      return;
    }

    final transferNotifier = ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final sendingFile in session.files.values) {
      if (transferNotifier.getStatus(sessionId: sessionId, fileId: sendingFile.file.id) == FileStatus.skipped) {
        // not accepted by the receiver
        continue;
      }
      final size = sendingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: sessionId, fileId: sendingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  Future<void> _sendLoop(String sessionId, Map<String, SendingFile> files, Object attempt) async {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(startTime: DateTime.now().millisecondsSinceEpoch),
    );

    await _sendFiles(
      sessionId: sessionId,
      files: files.values.toList(),
    );

    if (_currentAttempt(sessionId, attempt)) _finish(sessionId: sessionId);
  }

  void _finish({required String sessionId}) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }

    // The transfer is over, the process no longer needs to be kept alive for it.
    TransferNotification.stop(sessionId);

    if (state[sessionId]!.status != SessionStatus.sending) {
      _logger.info('Transfer was canceled.');
    } else {
      final classifiedStatus = ref.read(fileTransferProvider).classifyFailure(sessionId);
      final hasError = classifiedStatus != SessionStatus.finished;
      if (!hasError && sessionState.background == true && !_retainedSessions.contains(sessionId)) {
        closeSession(sessionId);
        _logger.info('Transfer finished and session removed.');
      } else {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: classifiedStatus,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        );

        if (hasError) {
          _logger.info('Transfer finished with status: $classifiedStatus');
        } else {
          _logger.info('Transfer finished successfully.');
        }
      }
    }
  }

  final uriContent = UriContent();

  /// Manual failed-file retries create an independent original-protocol queue
  /// task. Only the upload isolate performs same-token checksum retries.
  Future<void> sendFile({
    required String sessionId,
    required SendingFile file,
    required bool isRetry,
  }) async {
    if (isRetry) {
      ref.notifier(sendQueueProvider).retryFile(sessionId: sessionId, file: file);
      return;
    }
    // A non-retry single-file dispatch is only valid for an already prepared,
    // queued file. Failed/terminal tokens cannot enter this path.
    final original = state[sessionId];
    final currentFile = original?.files[file.file.id];
    if (_disposed ||
        original?.status != SessionStatus.sending ||
        file.token == null ||
        currentFile == null ||
        !identical(currentFile.file, file.file) ||
        currentFile.token != file.token ||
        ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: file.file.id) != FileStatus.queue) {
      return;
    }
    // Claim before the first await so duplicate dispatch cannot schedule the
    // same prepared token twice.
    ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: file.file.id, status: FileStatus.sending);
    final completed = await _sendFiles(sessionId: sessionId, files: [file]);
    if (completed && state[sessionId] != null && !ref.read(fileTransferProvider).hasPending(sessionId)) {
      _finish(sessionId: sessionId);
    }
  }

  /// Sends the given [files] as one isolate task.
  /// The isolate iterates through the list and reports the state of each file
  /// via [HttpUploadEvent]s.
  /// Files without a token (i.e. not selected by the receiver) are skipped.
  Future<bool> _sendFiles({
    required String sessionId,
    required List<SendingFile> files,
  }) async {
    final sessionState = state[sessionId];
    if (_disposed || sessionState == null || sessionState.status != SessionStatus.sending) {
      return false;
    }

    final sourceEnd = ref.notifier(sourceEndProvider);
    final sourceEndAttempt = _uuid.v4();
    final sourceEndFiles = <String>{};
    final sourceEndKeys = {
      for (final f in files)
        if (f.resumeKey != null) f.file.id: f.resumeKey!,
    };
    final sourceJob = sourceEnd.available ? ref.read(sendQueueProvider).where((job) => job.id == sessionId).firstOrNull : null;
    if (sourceEnd.available && sourceJob != null) {
      try {
        for (final file in files) {
          if (file.resumeKey != null &&
              file.file.size >= 1024 * 1024 &&
              await sourceEnd.track(
                job: sourceJob,
                jobId: sessionId,
                peer: sessionState.target,
                resumeKey: file.resumeKey!,
                name: file.file.fileName,
                attemptId: sourceEndAttempt,
                route: sessionState.localRoute,
              )) {
            sourceEndFiles.add(file.file.id);
          }
        }
      } catch (_) {
        for (final file in files) {
          ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: file.file.id, status: FileStatus.failed);
        }
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(errorMessage: t.general.error),
        );
        return true;
      }
      if (_disposed ||
          state[sessionId]?.status != SessionStatus.sending ||
          files.any((f) => !identical(state[sessionId]?.files[f.file.id]?.file, f.file))) {
        for (final id in sourceEndFiles) {
          await sourceEnd.unsupported(sessionState.target.fingerprint, sourceEndKeys[id]!, sourceEndAttempt);
        }
        await sourceEnd.endJob(sessionId);
        return false;
      }
    }
    final uploadFiles = [
      for (final file in files)
        if (file.token != null)
          HttpUploadFile(
            remoteFileToken: file.token!,
            fileId: file.file.id,
            filePath: file.path,
            fileBytes: file.bytes,
            fileSize: file.file.size,
            resumeKey: file.resumeKey,
            enableSourceEnd: sourceEndFiles.contains(file.file.id),
          ),
    ];

    if (uploadFiles.isEmpty) {
      return true;
    }

    final IsolateHttpUploadActionResult taskResult;
    try {
      taskResult = _upload(
        IsolateHttpUploadFilesAction(
          remoteSessionId: sessionState.remoteSessionId,
          files: uploadFiles,
          device: sessionState.target,
          localRoute: sessionState.localRoute,
        ),
      );
    } catch (error) {
      _failPendingFiles(sessionId, uploadFiles, _sendErrorMessage(error));
      return true;
    }
    final owner = SendingTask(taskId: taskResult.taskId);
    bool ownsTask() => !_disposed && state[sessionId]?.sendingTasks?.any((task) => identical(task, owner)) == true;
    bool active() => ownsTask() && state[sessionId]?.status == SessionStatus.sending;
    final acceptedIds = uploadFiles.map((file) => file.fileId).toSet();
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(sendingTasks: [...?s.sendingTasks, owner]),
    );

    final verificationAttempt = _uuid.v4();
    final startedProgress = <String>{};
    var completedCurrent = false;
    try {
      await for (final event in taskResult.events) {
        if (event is HttpUploadSourceEndGrantEvent) {
          var persisted = false;
          try {
            if (sourceEndFiles.contains(event.fileId)) {
              await sourceEnd.grant(
                peer: sessionState.target.fingerprint,
                resumeKey: sourceEndKeys[event.fileId]!,
                jobId: sessionId,
                attemptId: sourceEndAttempt,
                value: event.grant,
              );
              persisted = true;
            }
          } catch (_) {
            /* Negative acknowledgement stops opted-in durable sending. */
          } finally {
            try {
              final ack = IsolateHttpSourceEndAckAction(
                uploadTaskId: taskResult.taskId,
                fileId: event.fileId,
                ackId: event.ackId,
                persisted: persisted,
              );
              if (ackSourceEnd != null) {
                ackSourceEnd!(ack);
              } else {
                ref.redux(parentIsolateProvider).dispatch(ack);
              }
            } catch (_) {}
          }
          continue;
        }
        if (event is HttpUploadSourceEndUnavailableEvent) {
          if (sourceEndFiles.contains(event.fileId)) {
            try {
              await sourceEnd.unsupported(sessionState.target.fingerprint, sourceEndKeys[event.fileId]!, sourceEndAttempt);
            } catch (_) {}
          }
          continue;
        }
        if (!active() || !acceptedIds.contains(event.fileId)) continue;
        final status = ref.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: event.fileId);
        if (status == FileStatus.finished || status == FileStatus.failed || status == FileStatus.skipped) continue;
        switch (event) {
          case HttpUploadSourceEndGrantEvent() || HttpUploadSourceEndUnavailableEvent() || HttpSourceEndResultEvent():
            break;
          case HttpUploadFileStartedEvent():
            _logger.info('Sending ${state[sessionId]?.files[event.fileId]?.file.fileName}');
            ref.notifier(fileTransferProvider).beginVerificationAttempt(sessionId: sessionId, fileId: event.fileId, attemptId: verificationAttempt);
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.sending);
          case HttpUploadFileRecoveryEvent():
            ref
                .notifier(fileTransferProvider)
                .setRecovery(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  attemptId: verificationAttempt,
                  value: event.waiting ? UploadRecoveryState.waiting(attempt: event.attempt, retryAfterMs: event.retryAfterMs) : null,
                );
          case HttpUploadFileVerificationEvent():
            ref
                .notifier(fileTransferProvider)
                .setVerification(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  value: FileVerification(
                    attemptId: verificationAttempt,
                    verifiedBytes: event.verifiedBytes,
                    totalBytes: event.totalBytes,
                    receiving: false,
                  ),
                  verifying: true,
                );
          case HttpUploadFileProgressEvent():
            if (!event.progress.isFinite) continue;
            ref.notifier(fileTransferProvider).clearVerifications(sessionId, fileId: event.fileId);
            ref.notifier(fileTransferProvider).setRecovery(sessionId: sessionId, fileId: event.fileId, attemptId: verificationAttempt, value: null);
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: event.progress.clamp(0, 1),
                );
            if (startedProgress.add(event.fileId)) ref.notifier(transferSpeedProvider).rebase('send:$sessionId');
            _updateForegroundServiceProgress(sessionId);
          case HttpUploadFileFinishedEvent():
            if (sourceEndFiles.contains(event.fileId)) {
              try {
                await sourceEnd.completed(sessionState.target.fingerprint, sourceEndKeys[event.fileId]!);
              } catch (_) {}
            }
            if (!active()) continue;
            // set progress to 100% when successfully finished
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: 1,
                );
            _updateForegroundServiceProgress(sessionId);
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.finished);
          case HttpUploadFileFailedEvent():
            _logger.warning('Error while sending file ${state[sessionId]?.files[event.fileId]?.file.fileName}: ${event.error}');
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.failed);
            final recovery =
                event.recovery ??
                (event.retainedConfirmed == null
                    ? null
                    : UploadRecoveryFailure(
                        kind: UploadRecoveryFailureKind.retryable,
                        retention: event.retainedConfirmed! ? UploadRecoveryRetention.confirmed : UploadRecoveryRetention.unknown,
                      ));
            if (recovery?.kind == UploadRecoveryFailureKind.sourceChanged && sourceEndFiles.contains(event.fileId)) {
              try {
                await sourceEnd.sourceChanged(sessionId, sessionState.target.fingerprint, sourceEndKeys[event.fileId]!);
              } catch (_) {}
            }
            if (!active()) continue;
            if (recovery != null) {
              ref
                  .notifier(fileTransferProvider)
                  .setRecovery(
                    sessionId: sessionId,
                    fileId: event.fileId,
                    attemptId: verificationAttempt,
                    value: UploadRecoveryState.failed(recovery),
                  );
            }
            state = state.updateSession(
              sessionId: sessionId,
              state: (s) {
                final updated = s?.withFileError(
                  event.fileId,
                  recovery == null ? _sendErrorMessage(event.error) : uploadRecoveryMessage(recovery),
                );
                if (updated == null) return null;
                return updated.copyWith(
                  files: {
                    ...updated.files,
                    event.fileId: updated.files[event.fileId]!.copyWith(retainedAfterInterruption: recovery?.retainedConfirmed),
                  },
                );
              },
            );
        }
      }
      if (active()) _failPendingFiles(sessionId, uploadFiles, 'Upload task ended before every file completed');
    } catch (e, st) {
      if (active()) {
        _logger.warning('Error while sending files', e, st);
        _failPendingFiles(sessionId, uploadFiles, _sendErrorMessage(e));
      }
    } finally {
      completedCurrent = active();
      if (ownsTask()) {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(sendingTasks: s.sendingTasks?.where((task) => !identical(task, owner)).toList()),
        );
      }
    }
    // Do not let the caller's completion finalize a replaced/cancelled session.
    return completedCurrent &&
        !_disposed &&
        state[sessionId]?.status == SessionStatus.sending &&
        identical(state[sessionId]?.files.values.firstOrNull?.file, sessionState.files.values.firstOrNull?.file);
  }

  void _failPendingFiles(String sessionId, List<HttpUploadFile> uploadFiles, String error) {
    final transfer = ref.notifier(fileTransferProvider);
    final ids = uploadFiles
        .map((file) => file.fileId)
        .where((id) => {FileStatus.queue, FileStatus.sending}.contains(transfer.getStatus(sessionId: sessionId, fileId: id)))
        .toSet();
    if (ids.isEmpty) return;
    transfer.setStatuses(sessionId: sessionId, statuses: {for (final id in ids) id: FileStatus.failed});
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(files: s.files.map((id, file) => MapEntry(id, ids.contains(id) ? file.copyWith(errorMessage: error) : file))),
    );
  }

  /// Closes the send-session and sends a cancel event to the receiver.
  void cancelSession(String sessionId) => _cancelSession(sessionId, retainSession: false);

  void _cancelSession(String sessionId, {required bool retainSession}) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    if (!{SessionStatus.waiting, SessionStatus.sending}.contains(sessionState.status)) {
      if (!retainSession) closeSession(sessionId);
      return;
    }
    final remoteSessionId = sessionState.remoteSessionId;
    _attempts.remove(sessionId);
    _retainedSessions.remove(sessionId);

    if (retainSession) _cancelRunningRequests(sessionState);

    if (remoteSessionId != null) {
      late final Future<void> request;
      request = _notifyReceiverCanceled(sessionState).whenComplete(() {
        if (identical(_cancelRequests[sessionId], request)) unawaited(_cancelRequests.remove(sessionId));
      });
      _cancelRequests[sessionId] = request;
    }

    if (retainSession) {
      // Queue history keeps confirmed file results after cancel. It is terminal,
      // so it does not reserve the device or accept single-file session retries.
      TransferNotification.stop(sessionId);
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(status: SessionStatus.canceledBySender, sendingTasks: [], endTime: DateTime.now().millisecondsSinceEpoch),
      );
    } else {
      closeSession(sessionId);
    }
  }

  /// Queue callers wait for both local draining and the remote cancellation
  /// response before allowing another request to occupy this device's slot.
  Future<void> cancelSessionAndWait(String sessionId) async {
    _cancelSession(sessionId, retainSession: true);
    await _cancelRequests[sessionId];
  }

  Future<void> releaseRemoteSession(String sessionId) async {
    final session = state[sessionId];
    if (session != null && !session.files.values.any((file) => file.retainedAfterInterruption == false)) await _notifyReceiverCanceled(session);
  }

  Future<void> _notifyReceiverCanceled(SendSessionState session) async {
    if (session.remoteSessionId == null || session.target.ip == null) return;
    try {
      await ref
          .read(httpProvider)
          .pinnedTo(session.target.fingerprint, localRoute: session.localRoute)
          .cancel(
            protocol: session.target.getProtocolType(),
            ip: session.target.ip!,
            port: session.target.port,
            sessionId: session.remoteSessionId!,
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _logger.warning('Remote cancellation did not complete', e);
    }
  }

  void cancelSessionByReceiver(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null || !{SessionStatus.waiting, SessionStatus.sending}.contains(sessionState.status)) {
      return;
    }
    _attempts.remove(sessionId);
    _retainedSessions.remove(sessionId);
    TransferNotification.stop(sessionId);
    _cancelRunningRequests(sessionState);

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.canceledByReceiver,
        sendingTasks: [],
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _cancelRunningRequests(SendSessionState state) {
    if (!_disposed) {
      ref.notifier(fileTransferProvider).clearWaitingRecovery(state.sessionId);
      ref.notifier(fileTransferProvider).clearVerifications(state.sessionId);
    }
    _hashCancelTokens.remove(state.sessionId)?.cancel();
    _prepareUploadCancelTokens.remove(state.sessionId)?.cancel();

    for (final task in state.sendingTasks ?? <SendingTask>[]) {
      _cancelUpload(task.taskId);
    }
  }

  /// Closes the session
  void closeSession(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    TransferNotification.stop(sessionId);
    _attempts.remove(sessionId);
    _presentationAttempts.remove(sessionId);
    _retainedSessions.remove(sessionId);
    _cancelRunningRequests(sessionState);
    _routes.remove(sessionId)?.close();
    state = state.removeSession(ref, sessionId);
    // Keep the selection available for another device or another send.
    // Only the explicit selection controls should clear it.
  }

  void clearAllSessions() {
    for (final sessionId in state.keys.toList()) {
      closeSession(sessionId);
    }
    _attempts.clear();
    _presentationAttempts.clear();
    _retainedSessions.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _attempts.clear();
    _presentationAttempts.clear();
    _retainedSessions.clear();
    // The shared file-progress provider may already be disposed and also holds
    // receives. Release only resources owned here; do not publish teardown state.
    for (final session in state.values) {
      TransferNotification.stop(session.sessionId);
      try {
        _cancelRunningRequests(session);
      } catch (error, stack) {
        _logger.fine('Upload isolate already closed during disposal', error, stack);
      }
    }
    for (final route in _routes.values) {
      route.close();
    }
    _routes.clear();
    super.dispose();
  }

  void setBackground(String sessionId, bool background) {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(background: background),
    );
  }
}

extension on Map<String, SendSessionState> {
  Map<String, SendSessionState> updateSession({
    required String sessionId,
    required SendSessionState? Function(SendSessionState? old) state,
  }) {
    final newState = state(this[sessionId]);
    if (newState == null) {
      // no change
      return this;
    }
    return {
      ...this,
      sessionId: newState,
    };
  }

  Map<String, SendSessionState> removeSession(Ref ref, String sessionId) {
    ref.notifier(fileTransferProvider).removeSession(sessionId);
    return {...this}..remove(sessionId);
  }
}

extension on SendSessionState {
  SendSessionState withFileError(String fileId, String? errorMessage) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
