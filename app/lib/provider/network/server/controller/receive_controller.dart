import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page.dart' show HomeTab;
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/receive_session_lookup.dart';
import 'package:localsend_app/util/ui/transfer_route.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/dialogs/open_file_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/server.dart' show SessionEndReasonV2;
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('ReceiveController');

/// Handles all server events for receiving files.
/// The HTTP requests themselves are served by the Rust server which emits
/// the events handled here.
class ReceiveController {
  final ServerUtils server;
  final Future<String> Function() resolveDefaultDestination;
  final Future<String> Function() resolveCache;

  ReceiveController(this.server, {this.resolveDefaultDestination = getDefaultDestinationDirectory, this.resolveCache = getCacheDirectory});

  String? _preparingSessionId;
  // Transport completion may precede the child's publication/post-processing
  // result. Keep that final result eligible without retaining a retry lease.
  String? _finishedSessionId;
  int _revision = 0;

  /// Called synchronously when the listener is invalidated, before teardown awaits.
  /// Only local receive ownership is released; never send commands to a new listener.
  void onServerStopped() {
    _revision++;
    _preparingSessionId = null;
    _finishedSessionId = null;
    closeSession();
    for (final entry in _routes.entries.toList()) {
      TransferNotification.stop(entry.key);
      server.ref.notifier(fileTransferProvider).removeSession(entry.key);
      entry.value.close();
    }
    _routes.clear();
    _pendingPromptRoutes.clear();
  }

  final _routes = <String, TransferRoute>{};
  final _pendingPromptRoutes = <String>{};

  bool _matches(String? expectedSessionId, {int? listenerGeneration, int? revision}) =>
      (listenerGeneration == null || server.getListenerGeneration() == listenerGeneration) &&
      (revision == null || _revision == revision) &&
      (expectedSessionId == null || server.getStateOrNull()?.session?.sessionId == expectedSessionId);

  Future<void> _recordHistory(AddHistoryEntryAction action) async {
    try {
      await server.ref.redux(receiveHistoryProvider).dispatchAsync(action);
    } catch (error) {
      // History is a best-effort record of bytes already published. It must not
      // keep a completed transfer active or prevent a new receive prompt.
      _logger.warning('Receive history persistence failed (${error.runtimeType})');
    }
  }

  /// A device registered itself on this server.
  Future<void> onRegister(HttpServerRegisterEvent event) async {
    if (event.info.fingerprint == server.ref.read(securityProvider).certificateHash) {
      // "I talked to myself lol"
      return;
    }

    // Feed the device into the discovery store; it comes back (and is
    // registered) via the [StartDiscoveryListener] stream.
    server.ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryAddDeviceAction(device: event.info.toDevice(event.ip, withChannel: true)));
    server.ref.notifier(discoveryLoggerProvider).addLog('[DISCOVER/TCP] Received "/register" HTTP request: ${event.info.alias} (${event.ip})');
  }

  /// A sender requests to upload files.
  /// The Rust server already checked the PIN and enforces that only one
  /// session can be active at a time.
  Future<void> onPrepareUpload(HttpServerPrepareUploadEvent event) async {
    if (server.getStateOrNull() == null) return;
    if (server.getStateOrNull()?.session != null) {
      // The Rust server is the authority on the single-session invariant:
      // a new request means the old session is over (e.g. finished but still
      // displayed, or aborted while waiting).
      closeSession();
    }

    final listenerGeneration = server.getListenerGeneration();
    final revision = ++_revision;
    _preparingSessionId = event.sessionId;
    _finishedSessionId = null;
    bool preparingCurrent() =>
        _preparingSessionId == event.sessionId &&
        server.getStateOrNull() != null &&
        _matches(null, listenerGeneration: listenerGeneration, revision: revision);
    final settings = server.ref.read(settingsProvider);
    final sessionId = event.sessionId;
    final String destinationDir;
    final String cacheDir;
    try {
      destinationDir = settings.destination ?? await resolveDefaultDestination();
      if (!preparingCurrent()) return;
      cacheDir = await resolveCache();
    } catch (error) {
      if (!preparingCurrent()) return;
      _preparingSessionId = null;
      // Resolve the protocol decision even when storage setup fails. Leaving a
      // oneshot unanswered would hold the receive slot until the peer times out.
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(sessionId: sessionId, config: null));
      _logger.warning('Receive directory lookup failed (${error.runtimeType})');
      // ignore: use_build_context_synchronously
      final context = Routerino.navigatorKey.currentContext;
      if (context != null && context.mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => ErrorDialog(error: t.receivePage.destinationUnavailable),
          ),
        );
      }
      return;
    }
    if (!preparingCurrent()) return;
    _preparingSessionId = null;
    final files = {
      for (final entry in event.files.entries) entry.key: entry.value.toDart(),
    };

    // Seed local selection before exposing the pending session to remote native
    // task controls; their accept action uses the same selection as this page.
    server.ref.notifier(selectedReceivingFilesProvider).setFiles(files.values.toList());

    // The fingerprint of the sender's mTLS certificate cannot be spoofed, unlike the
    // self-reported fingerprint in the JSON payload which is only used as fallback
    // when encryption is disabled.
    final senderFingerprint = event.certFingerprint ?? event.info.fingerprint;

    _logger.info('Session Id: $sessionId');
    _logger.info('Destination Directory: $destinationDir');

    server.setState(
      (oldState) => oldState?.copyWith(
        session: ReceiveSessionState(
          sessionId: sessionId,
          status: SessionStatus.waiting,
          sender: event.info.toDevice(event.ip, withChannel: false).copyWith(fingerprint: senderFingerprint),
          senderAlias: server.ref.read(favoritesProvider).firstWhereOrNull((e) => e.fingerprint == senderFingerprint)?.alias ?? event.info.alias,
          files: {
            for (final file in files.values)
              file.id: ReceivingFile(
                file: file,
                token: null,
                desiredName: null,
                path: null,
                savedToGallery: false,
                errorMessage: null,
              ),
          },
          startTime: null,
          endTime: null,
          destinationDirectory: destinationDir,
          cacheDirectory: cacheDir,
          saveToGallery: checkPlatformWithGallery() && settings.saveToGallery && files.values.every((f) => !f.fileName.contains('/')),
          createdDirectories: {},
        ),
      ),
    );

    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {for (final file in files.values) file.id: FileStatus.queue},
        );

    bool quickSave = settings.quickSave && server.getState().session?.message == null;
    final quickSaveFromFavorites = settings.quickSaveFromFavorites && server.getState().session?.message == null;
    if (quickSaveFromFavorites) {
      final bool isFavorite = server.ref.read(favoritesProvider).any((e) => e.fingerprint == senderFingerprint);
      if (isFavorite) {
        quickSave = true;
      }
    }
    if (event.info.deviceType?.toDart() == DeviceType.web &&
        server.getState().webUpload &&
        settings.receiveViaLinkAutoAccept &&
        server.getState().session?.message == null) {
      // The upload page (receive via link) is being served and requests should be accepted automatically.
      quickSave = true;
    }

    if (quickSave) {
      // ignore: use_build_context_synchronously
      final route = _routes[sessionId] = TransferRoute(Routerino.context);
      unawaited(route.show((_) => ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: sessionId, receiving: true)));
      await acceptFileRequest({for (final f in files.values) f.id: f.fileName}, expectedSessionId: sessionId);
      return;
    }

    if (checkPlatformHasTray()) {
      final minimized = await windowManager.isMinimized();
      if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
      final visible = minimized || await windowManager.isVisible();
      if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
      final focused = minimized || !visible || await windowManager.isFocused();
      if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
      if (minimized || !visible || !focused) await showFromTray();
    }

    if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
    final message = server.getState().session?.message;
    if (message != null) {
      // Message already received
      unawaited(
        _recordHistory(
          AddHistoryEntryAction(
            entryId: const Uuid().v4(),
            fileName: message,
            fileType: FileType.text,
            path: null,
            savedToGallery: false,
            isMessage: true,
            fileSize: utf8.encode(message).length,
            senderAlias: server.getState().session!.senderAlias,
            timestamp: DateTime.now().toUtc(),
          ),
        ),
      );
    }

    if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
    // ignore: use_build_context_synchronously
    final route = _routes[sessionId] = TransferRoute(Routerino.context);
    _pendingPromptRoutes.add(sessionId);
    final receiveProvider = ViewProvider((ref) {
      // No select: comparing the selected session runs the dart_mappable deep equality
      // over the whole files map on every state change.
      final session = receiveSessionForId(ref.watch(serverProvider)?.session, sessionId);
      return ReceivePageVm(
        sessionId: sessionId,
        onDismiss: route.close,
        status: session?.status,
        sender: session?.sender ?? Device.empty,
        showSenderInfo: true,
        files: session?.files.values.map((f) => f.file).toList() ?? [],
        message: message,
        onAccept: () async {
          if (!_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision) ||
              server.getState().session?.status != SessionStatus.waiting) {
            return;
          }
          final selected = message != null ? <String, String>{} : Map<String, String>.of(ref.read(selectedReceivingFilesProvider));
          await acceptFileRequest(selected, expectedSessionId: sessionId);
        },
        onDecline: () {
          if (_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) {
            declineFileRequest(expectedSessionId: sessionId);
          }
        },
        onClose: () {
          if (_matches(sessionId, listenerGeneration: listenerGeneration, revision: revision)) {
            closeSession(expectedSessionId: sessionId);
          }
        },
      );
    });

    // ignore: use_build_context_synchronously, unawaited_futures
    unawaited(route.show((_) => ReceivePage(receiveProvider)));
  }

  /// An accepted file started being uploaded.
  /// The server isolate receives and saves the file on its own
  /// ([HttpServerReceiveConfig] was sent with the accept decision);
  /// only the session state is updated here.
  void onFileUpload(HttpServerFileUploadEvent event) {
    // A finished transport has no further accepted attempts. Its delayed final
    // result is still processed separately below.
    if (_finishedSessionId == event.sessionId) return;
    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      _logger.warning('Failing upload of file ${event.fileId}: no matching active session');
      // Fail the upload (and any further ones) by cancelling the session on the Rust side.
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    // An integrity stage has its own identity and never changes network bytes.
    server.ref
        .notifier(fileTransferProvider)
        .beginReceiveAttempt(sessionId: event.sessionId, fileId: fileId, attemptId: event.attemptId, owner: server.getListenerGeneration());
    // begin of actual file transfer
    server.ref.notifier(fileTransferProvider).setProgress(sessionId: event.sessionId, fileId: fileId, progress: 0);
    server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.sending);
    if (receiveState.startTime == null || receiveState.status != SessionStatus.sending) {
      server.setState(
        (oldState) => oldState?.copyWith(
          session: receiveState.copyWith(
            startTime: receiveState.startTime ?? DateTime.now().millisecondsSinceEpoch,
            endTime: null,
            status: SessionStatus.sending, // in case it was finishedWithErrors and user retries a failed file
          ),
        ),
      );
    }
  }

  void onFileVerification(HttpServerFileVerificationEvent event) {
    if (_finishedSessionId == event.sessionId) return;
    final session = server.getStateOrNull()?.session;
    if (session == null ||
        session.sessionId != event.sessionId ||
        session.status != SessionStatus.sending ||
        session.files[event.fileId]?.desiredName == null ||
        session.files[event.fileId]?.file.size != event.totalBytes) {
      return;
    }
    server.ref
        .notifier(fileTransferProvider)
        .setVerification(
          sessionId: event.sessionId,
          fileId: event.fileId,
          owner: server.getListenerGeneration(),
          value: FileVerification(attemptId: event.attemptId, verifiedBytes: event.verifiedBytes, totalBytes: event.totalBytes),
          verifying: event.verifying,
        );
  }

  /// The receive progress of a file reported by the server isolate.
  void onFileUploadProgress(HttpServerFileUploadProgressEvent event) {
    final receiveState = server.getStateOrNull()?.session;
    if (receiveState == null ||
        receiveState.sessionId != event.sessionId ||
        receiveState.status != SessionStatus.sending ||
        receiveState.files[event.fileId]?.desiredName == null) {
      return;
    }

    final transfer = server.ref.notifier(fileTransferProvider);
    if (!transfer.ownsReceiveAttempt(
      sessionId: event.sessionId,
      fileId: event.fileId,
      attemptId: event.attemptId,
      owner: server.getListenerGeneration(),
    )) {
      return;
    }
    transfer.clearVerifications(event.sessionId, fileId: event.fileId);
    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: event.sessionId,
          fileId: event.fileId,
          progress: event.progress,
        );

    if (event.attemptId != null && transfer.markReceiveTransportStarted(sessionId: event.sessionId, fileId: event.fileId)) {
      server.ref.notifier(transferSpeedProvider).rebase('receive:${event.sessionId}');
    }
    _updateForegroundServiceProgress(receiveState);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(ReceiveSessionState session) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final transferNotifier = server.ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final receivingFile in session.files.values) {
      if (receivingFile.desiredName == null) {
        // not accepted by the user
        continue;
      }
      final size = receivingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: session.sessionId, fileId: receivingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: session.sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  /// Published success receipts outlive a socket listener. This entry point is
  /// history-only: never inspect or mutate a current session or its UI leases.
  Future<void> onReceiveReceipt(HttpServerFileUploadResultEvent event) async {
    final receipt = event.error == null ? event.receipt : null;
    if (receipt == null) return;
    await _recordHistory(
      AddHistoryEntryAction(
        entryId: receipt.receiptId,
        receiptId: receipt.receiptId,
        fileName: receipt.fileName,
        fileType: receipt.fileType,
        path: event.path,
        savedToGallery: event.savedToGallery,
        isMessage: false,
        fileSize: receipt.fileSize,
        senderAlias: receipt.senderAlias,
        timestamp: receipt.timestamp,
      ),
    );
  }

  /// A file has been received completely (or failed) by the server isolate.
  Future<void> onFileUploadResult(HttpServerFileUploadResultEvent event) async {
    final history = onReceiveReceipt(event);
    try {
      await _applyFileUploadResult(event);
    } finally {
      // UI completion above does not wait on a slow history write.
      await history;
    }
  }

  Future<void> _applyFileUploadResult(HttpServerFileUploadResultEvent event) async {
    final listenerGeneration = server.getListenerGeneration();
    final revision = _revision;
    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      return;
    }

    if (!server.ref
        .read(fileTransferProvider)
        .ownsReceiveAttempt(sessionId: event.sessionId, fileId: event.fileId, attemptId: event.attemptId, owner: listenerGeneration)) {
      return;
    }
    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      return;
    }

    // Rust emits a fresh FileUpload before each retry. A terminal callback may
    // be duplicated/delayed by consumers, but can complete each started file once.
    if (server.ref.read(fileTransferProvider).getStatus(sessionId: event.sessionId, fileId: fileId) != FileStatus.sending) return;

    final fileType = receivingFile.file.fileType;
    final filePath = event.path;
    final error = event.error;

    if (error == null) {
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.finished);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: filePath,
            savedToGallery: event.savedToGallery,
            errorMessage: null,
          ),
        ),
      );
    } else {
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.failed);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: null,
            savedToGallery: false,
            errorMessage: error,
          ),
        ),
      );
    }

    if (!_matches(receiveState.sessionId, listenerGeneration: listenerGeneration, revision: revision)) return;
    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: receiveState.sessionId,
          fileId: fileId,
          progress: 1,
        );

    final session = server.getStateOrNull()?.session;
    if (session == null || session.sessionId != receiveState.sessionId) {
      return;
    }

    _updateForegroundServiceProgress(session);

    final pending = server.ref.read(fileTransferProvider).hasPending(session.sessionId);
    if (allowedStates.contains(session.status) && !pending) {
      final hasError = server.ref.read(fileTransferProvider).hasFailed(session.sessionId);
      // A failed file remains retryable in the original protocol until Rust
      // ends the session. Retain its existing foreground membership rather than
      // attempting to restart a service from the background when a retry arrives.
      if (!hasError || _finishedSessionId == session.sessionId) TransferNotification.stop(session.sessionId);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session!.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      final settings = server.ref.read(settingsProvider);
      // Only auto-close fully successful sessions: a failed file may still be
      // retried by the sender (e.g. after a checksum mismatch), which requires
      // the session to stay open.
      bool quickSave = settings.quickSave && !hasError && server.getState().session?.message == null;
      final quickSaveFromFavorites = settings.quickSaveFromFavorites && !hasError && server.getState().session?.message == null;
      if (quickSaveFromFavorites) {
        final bool isFavorite = server.ref.read(favoritesProvider).any((e) => e.fingerprint == session.sender.fingerprint);
        if (isFavorite) {
          quickSave = true;
        }
      }
      if (quickSave) {
        // close the session **after** the response has been sent
        Future.delayed(Duration.zero, () {
          if (!_matches(session.sessionId, listenerGeneration: listenerGeneration, revision: revision) ||
              server.getStateOrNull()?.session?.status != SessionStatus.finished) {
            return;
          }
          final wasCurrent = _routes[session.sessionId]?.isCurrent == true;
          closeSession(expectedSessionId: session.sessionId);
          _logger.info('Closing session');

          // open the dialog to open file instantly
          if (wasCurrent &&
              server.getListenerGeneration() == listenerGeneration &&
              _revision == revision + 1 &&
              server.getStateOrNull()?.session == null &&
              filePath != null &&
              filePath.isNotEmpty) {
            // ignore: discarded_futures
            OpenFileDialog.open(
              Routerino.context, // ignore: use_build_context_synchronously
              filePath: filePath,
              fileType: fileType,
              openGallery: event.savedToGallery,
            );
          }
        });
      }
      _logger.info('Received all files.');
    }
    if (error == null && event.receipt == null) {
      // Published-file history is independent of the session's remaining lifetime.
      await _recordHistory(
        AddHistoryEntryAction(
          entryId: fileId,
          fileName: receivingFile.desiredName!,
          fileType: fileType,
          path: filePath,
          savedToGallery: event.savedToGallery,
          isMessage: false,
          fileSize: receivingFile.file.size,
          senderAlias: receiveState.senderAlias,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
  }

  /// An upload session ended on the Rust server.
  /// The destination grant failed locally, not a cancellation by the sender.
  void onDestinationUnavailable(HttpServerReceiveDestinationErrorEvent event) {
    final session = server.getStateOrNull()?.session;
    if (session == null ||
        session.sessionId != event.sessionId ||
        (session.status != SessionStatus.waiting && session.status != SessionStatus.sending)) {
      return;
    }
    _revision++;
    _finishedSessionId = event.sessionId;
    final progress = server.ref.notifier(fileTransferProvider);
    progress.clearVerifications(event.sessionId);
    final files = {...session.files};
    for (final entry in files.entries.toList()) {
      final status = progress.getStatus(sessionId: event.sessionId, fileId: entry.key);
      if (status == FileStatus.finished || status == FileStatus.skipped) continue;
      progress.setStatus(sessionId: event.sessionId, fileId: entry.key, status: FileStatus.failed);
      files[entry.key] = entry.value.copyWith(errorMessage: t.receivePage.destinationUnavailable);
    }
    server.setState(
      (state) => state?.copyWith(
        session: session.copyWith(
          status: SessionStatus.finishedWithErrors,
          files: files,
          endTime: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
    TransferNotification.stop(event.sessionId);
    if (_pendingPromptRoutes.remove(event.sessionId)) _routes.remove(event.sessionId)?.close();
  }

  void onSessionEnd(HttpServerSessionEndEvent event) {
    if (_preparingSessionId == event.sessionId) _preparingSessionId = null;
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null || receiveSession.sessionId != event.sessionId) {
      return;
    }

    server.ref.notifier(fileTransferProvider).clearVerifications(event.sessionId);
    switch (event.reason) {
      case SessionEndReasonV2.finished:
        _finishedSessionId = event.sessionId;
        // Rust completion can arrive before FileUploadResult from the child's
        // independent upload queue. Never discard that pending publication or
        // history outcome. If the UI already finished, only release its lease.
        if (receiveSession.status == SessionStatus.finished || receiveSession.status == SessionStatus.finishedWithErrors) {
          TransferNotification.stop(event.sessionId);
        }
        break;
      case SessionEndReasonV2.expired:
        if (_finishedSessionId == event.sessionId) return;
        _finishedSessionId = event.sessionId;
        _revision++;
        final progress = server.ref.notifier(fileTransferProvider);
        final files = {...receiveSession.files};
        for (final entry in files.entries.toList()) {
          final status = progress.getStatus(sessionId: event.sessionId, fileId: entry.key);
          if (status == FileStatus.finished || status == FileStatus.skipped) continue;
          progress.setStatus(sessionId: event.sessionId, fileId: entry.key, status: FileStatus.failed);
          files[entry.key] = entry.value.copyWith(errorMessage: t.receivePage.idleExpired);
        }
        server.setState(
          (state) => state?.copyWith(
            session: receiveSession.copyWith(
              status: SessionStatus.finishedWithErrors,
              endTime: DateTime.now().millisecondsSinceEpoch,
              files: files,
            ),
          ),
        );
        TransferNotification.stop(event.sessionId);
        // A waiting decision has become invalid. Close only its owned prompt;
        // an active result page remains available with the truthful failure.
        if (_pendingPromptRoutes.remove(event.sessionId)) _routes.remove(event.sessionId)?.close();
        break;
      case SessionEndReasonV2.cancelled:
        _cancelBySender(server);
    }
  }

  /// The server rejected/aborted preparation, including a permission change
  /// racing with our already-submitted accept decision. Rust has not activated
  /// this session, even when the UI optimistically moved to sending.
  void onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent event) {
    if (_preparingSessionId == event.sessionId) _preparingSessionId = null;
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null ||
        receiveSession.sessionId != event.sessionId ||
        (receiveSession.status != SessionStatus.waiting && receiveSession.status != SessionStatus.sending)) {
      return;
    }

    _cancelBySender(server);
  }

  /// A remote device cancels a transfer this application is currently
  /// *sending* to it.
  void onCancelReceived(HttpServerCancelReceivedEvent event) {
    final sendSessions = server.ref.read(sendProvider);
    final selectedSession = sendSessions.values.firstWhereOrNull((s) => s.remoteSessionId == event.sessionId);
    if (selectedSession == null) {
      return;
    }

    if (selectedSession.target.ip != event.ip) {
      return;
    }

    if (selectedSession.status != SessionStatus.sending) {
      return;
    }

    server.ref
        .notifier(sendProvider)
        .cancelSessionByReceiver(
          selectedSession.sessionId,
        );
  }

  /// Another application instance requested the running application to show itself.
  /// The show token has already been checked by the Rust server.
  void onShow(HttpServerShowEvent event) {
    if (!checkPlatformIsDesktop()) {
      return;
    }

    // ignore: discarded_futures
    showFromTray().catchError((e) {
      // don't wait for it
      _logger.severe('Failed to show from tray', e);
    });

    final args = event.args;
    if (args.isEmpty) {
      return;
    }

    // ignore: unawaited_futures, discarded_futures
    server.ref.redux(selectedSendingFilesProvider).dispatchAsyncTakeResult(LoadSelectionFromArgsAction(args)).then((filesAdded) {
      if (filesAdded) {
        server.ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
      }
    });
  }

  /// Accepts the file request with the given [fileNameMap] (file id -> desired file name).
  Future<void> acceptFileRequest(Map<String, String> fileNameMap, {String? expectedSessionId}) async {
    if (!_matches(expectedSessionId)) return;
    final listenerGeneration = server.getListenerGeneration();
    final revision = _revision;
    fileNameMap = Map<String, String>.unmodifiable(fileNameMap);
    final session = server.getStateOrNull()?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      return;
    }

    if (fileNameMap.isEmpty) {
      // nothing selected, the Rust server responds with 204 and creates no session
      // This usually happens for message transfers
      server.ref
          .redux(parentIsolateProvider)
          .dispatch(IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: _buildReceiveConfig(session, {})));
      closeSession(expectedSessionId: expectedSessionId);
      return;
    }

    server.setState(
      (oldState) {
        final receiveState = oldState!.session!;
        return oldState.copyWith(
          session: receiveState.copyWith(
            status: SessionStatus.sending,
            files: Map.fromEntries(
              receiveState.files.values.map((entry) {
                final desiredName = fileNameMap[entry.file.id];
                return MapEntry(
                  entry.file.id,
                  ReceivingFile(
                    file: entry.file,
                    token: null,
                    desiredName: desiredName,
                    path: null,
                    savedToGallery: false,
                    errorMessage: null,
                  ),
                );
              }),
            ),
          ),
        );
      },
    );

    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: session.sessionId,
          statuses: {
            for (final file in session.files.values) file.file.id: fileNameMap.containsKey(file.file.id) ? FileStatus.queue : FileStatus.skipped,
          },
        );

    if (_pendingPromptRoutes.remove(session.sessionId)) {
      final route = _routes[session.sessionId];
      if (route != null && route.isOpen) {
        unawaited(route.show((_) => ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: session.sessionId, receiving: true)));
      }
    }

    // The storage permission only exists below Android 13 (scoped storage): newer versions
    // auto-deny the request, but the round trip through the system permission activity
    // still blocks the UI noticeably.
    final androidSdkInt = server.ref.read(deviceInfoProvider).androidSdkInt;
    if (checkPlatform([TargetPlatform.android]) && androidSdkInt != null && androidSdkInt < 33) {
      try {
        final result = await Permission.storage.request();
        _logger.info('storage permission: $result');
      } catch (e) {
        _logger.warning('Could not request storage permission', e);
      }
    }

    // Keep the process alive for the whole transfer. Started here because:
    // - the app is still in the foreground, and Android 12+ rejects starting a foreground service
    //   from the background,
    // - the service may ask for the notification permission, which Android cancels when it overlaps
    //   with the storage permission requests above.
    if (!_matches(session.sessionId, listenerGeneration: listenerGeneration, revision: revision) ||
        server.getStateOrNull()?.session?.status != SessionStatus.sending) {
      return;
    }
    TransferNotification.start(sessionId: session.sessionId, receiving: true);

    // From here on, the server isolate receives all accepted files on its own
    // and reports back via upload progress/result events.
    final updatedSession = server.getStateOrNull()?.session;
    if (updatedSession == null || updatedSession.sessionId != session.sessionId) {
      return;
    }
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: _buildReceiveConfig(updatedSession, fileNameMap)),
        );
  }

  HttpServerReceiveConfig _buildReceiveConfig(ReceiveSessionState session, Map<String, String> fileNameMap) {
    return HttpServerReceiveConfig(
      sessionId: session.sessionId,
      senderAlias: session.senderAlias,
      fileNameMap: fileNameMap,
      destinationDirectory: session.destinationDirectory,
      cacheDirectory: session.cacheDirectory,
      saveToGallery: session.saveToGallery,
      androidSdkInt: server.ref.read(deviceInfoProvider).androidSdkInt,
    );
  }

  void declineFileRequest({String? expectedSessionId}) {
    if (!_matches(expectedSessionId)) return;
    final session = server.getStateOrNull()?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      return;
    }

    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: null));
    closeSession(expectedSessionId: expectedSessionId);
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory, {String? expectedSessionId}) {
    if (!_matches(expectedSessionId)) return;
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          destinationDirectory: destinationDirectory,
        ),
      ),
    );
  }

  /// Updates the "saveToGallery" setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery, {String? expectedSessionId}) {
    if (!_matches(expectedSessionId)) return;
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          saveToGallery: saveToGallery,
        ),
      ),
    );
  }

  /// In addition to [closeSession], this method also
  /// - cancels the session on the Rust server so that further uploads fail
  /// - notifies the sender that the session has been canceled
  void cancelSession({String? expectedSessionId}) {
    if (!_matches(expectedSessionId)) return;
    final session = server.getStateOrNull()?.session;
    if (session == null) {
      // the server is not running
      return;
    }

    // fail further uploads
    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: session.sessionId));

    // notify sender
    final target = session.sender;
    try {
      unawaited(
        server.ref
            .read(httpProvider)
            .pinnedTo(target.fingerprint)
            .cancel(
              protocol: target.getProtocolType(),
              ip: target.ip!,
              port: target.port,
              sessionId: session.sessionId,
            )
            .catchError((Object error, StackTrace stack) {
              _logger.warning('Failed to notify sender (${error.runtimeType})');
            }),
      );
    } catch (e) {
      _logger.warning('Failed to notify sender', e);
    }

    closeSession(expectedSessionId: expectedSessionId);
  }

  void closeSession({String? expectedSessionId}) {
    if (!_matches(expectedSessionId)) return;
    final sessionId = server.getStateOrNull()?.session?.sessionId;
    if (sessionId == null) {
      return;
    }

    _revision++;
    if (_finishedSessionId == sessionId) _finishedSessionId = null;
    TransferNotification.stop(sessionId);
    _pendingPromptRoutes.remove(sessionId);
    _routes.remove(sessionId)?.close();

    server.setState(
      (oldState) => oldState?.copyWith(
        session: null,
      ),
    );
    server.ref.notifier(fileTransferProvider).removeSession(sessionId);
  }
}

void _cancelBySender(ServerUtils server) {
  final receiveSession = server.getStateOrNull()?.session;
  if (receiveSession == null) {
    return;
  }

  TransferNotification.stop(receiveSession.sessionId);

  server.setState(
    (oldState) => oldState?.copyWith(
      session: oldState.session?.copyWith(
        status: SessionStatus.canceledBySender,
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    ),
  );
}

extension on ReceiveSessionState {
  ReceiveSessionState fileFinished({
    required String fileId,
    required String? path,
    required bool savedToGallery,
    required String? errorMessage,
  }) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            path: path,
            savedToGallery: savedToGallery,
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
