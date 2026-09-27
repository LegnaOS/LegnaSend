import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/web/web_download_file.dart';
import 'package:localsend_app/model/state/send/web/web_download_session.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/user_agent_analyzer.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/rust/api/server.dart' as native_server;
import 'package:localsend_isolates/util/android_channel.dart' as isolate_android_channel;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

final _logger = Logger('WebDownloadController');

/// Handles all server events for web download (sending files to web browsers).
/// The web page and the downloads themselves are served by the Rust server
/// which emits the events handled here.
class SendController {
  final ServerUtils server;

  final Future<void> Function(String sessionId, bool accept)? sendDecision;
  final Map<String, WebDownloadSession> _deciding = {};
  final Future<int> Function(String uri)? resolveDescriptor;
  final Future<void> Function(int descriptor)? releaseDescriptor;
  final void Function(HttpServerWebFileDownloadEvent event, String? path, int? descriptor)? downloadTarget;
  final void Function(HttpServerWebFileDownloadEvent event)? downloadFailed;

  SendController(this.server, {this.sendDecision, this.resolveDescriptor, this.releaseDescriptor, this.downloadTarget, this.downloadFailed});

  /// Invalidate controller-owned in-flight approvals without contacting a new listener.
  void onServerStopped() => _deciding.clear();

  void _failDownload(HttpServerWebFileDownloadEvent event) {
    if (downloadFailed != null) {
      downloadFailed!(event);
      return;
    }
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(IsolateHttpServerFailFileDownloadAction(requestId: event.requestId, sessionId: event.sessionId, fileId: event.fileId));
  }

  void _provideDownload(HttpServerWebFileDownloadEvent event, String? path, int? descriptor) {
    if (downloadTarget != null) {
      downloadTarget!(event, path, descriptor);
      return;
    }
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateHttpServerFileDownloadTargetAction(
            requestId: event.requestId,
            sessionId: event.sessionId,
            fileId: event.fileId,
            path: path,
            fileDescriptor: descriptor,
          ),
        );
  }

  Future<void> _releaseDescriptor(int descriptor) =>
      releaseDescriptor?.call(descriptor) ?? native_server.discardDownloadSource(fileDescriptor: descriptor);

  Future<void> _sendDecision(String sessionId, bool accept) async {
    if (sendDecision != null) return sendDecision!(sessionId, accept);
    await server.ref.redux(parentIsolateProvider).dispatchAsync(IsolateHttpServerPrepareDownloadDecisionAction(sessionId: sessionId, accept: accept));
  }

  /// Builds the [WebDownloadState] for the given [files].
  /// Files that only exist in memory (e.g. text messages) are materialized
  /// to the cache directory so the Rust server can stream them.
  Future<WebDownloadState> buildWebDownloadState({required List<CrossFile> files}) async {
    final currentWebDownloadState = server.getStateOrNull()?.webDownloadState;

    return WebDownloadState(
      sessions: {},
      files: Map.fromEntries(
        await Future.wait(
          files.map((file) async {
            final id = _uuid.v4();

            String? path = file.path;
            if (path == null && file.bytes != null) {
              // The Rust server streams file content from disk, so in-memory
              // bytes (text messages, clipboard content) are written to a temp file.
              final tempPath = p.join(await getCacheDirectory(), 'web-download-$id');
              await File(tempPath).writeAsBytes(file.bytes!);
              path = tempPath;
            }

            return MapEntry(
              id,
              WebDownloadFile(
                file: FileDto(
                  id: id,
                  fileName: file.name,
                  size: file.size,
                  fileType: file.fileType,
                  hash: null,
                  preview: files.length == 1 && file.fileType == FileType.text && file.bytes != null
                      ? utf8.decode(file.bytes!) // send simple message by embedding it into the preview
                      : null,
                  metadata: file.lastModified != null || file.lastAccessed != null
                      ? FileMetadata(
                          lastModified: file.lastModified,
                          lastAccessed: file.lastAccessed,
                        )
                      : null,
                ),
                asset: file.asset,
                path: path,
                bytes: file.bytes,
              ),
            );
          }),
        ),
      ),
      autoAccept: currentWebDownloadState?.autoAccept ?? server.ref.read(settingsProvider).shareViaLinkAutoAccept,
    );
  }

  /// A web client requests to download the shared files.
  /// The Rust server already checked the PIN and handles repeated visits of
  /// accepted sessions itself.
  void onPrepareDownload(HttpServerWebPrepareDownloadEvent event) {
    final webDownloadState = server.getStateOrNull()?.webDownloadState;
    if (webDownloadState == null) {
      // should not happen: web download events are only emitted when web download was configured
      unawaited(
        _sendDecision(event.sessionId, false).catchError((Object error, StackTrace st) {
          _logger.fine('Ended approval no longer has a responder', error, st);
        }),
      );
      return;
    }

    if (webDownloadState.sessions.containsKey(event.sessionId)) return;

    server.setState(
      (oldState) => oldState!.updateWebDownloadState(
        (webDownload) => webDownload.copyWith(
          sessions: {
            ...webDownload.sessions,
            event.sessionId: WebDownloadSession(
              sessionId: event.sessionId,
              pending: true,
              ip: event.ip,
              deviceInfo: parseDeviceInfoFromUserAgent(event.userAgent),
            ),
          },
        ),
      ),
    );

    if (webDownloadState.autoAccept) {
      unawaited(acceptRequest(event.sessionId));
    }
  }

  /// A web client downloads an offered file.
  /// The Rust server already validated the session; it streams the content
  /// from the source resolved here.
  Future<void> onFileDownload(HttpServerWebFileDownloadEvent event) async {
    final listener = server.getListenerGeneration();
    final source = server.getStateOrNull()?.webDownloadState?.files[event.fileId];
    bool sameListener() => server.getListenerGeneration() == listener && server.getStateOrNull() != null;
    bool sourceActive() => sameListener() && identical(server.getStateOrNull()?.webDownloadState?.files[event.fileId], source);
    int? descriptor;
    try {
      final path = source?.path;
      if (path == null) throw StateError('No path for web download file ${event.fileId}');
      if (path.startsWith('content://')) {
        descriptor = await (resolveDescriptor?.call(path) ?? isolate_android_channel.getFileDescriptorAndroid(uri: path));
      }
      if (!sourceActive()) {
        if (descriptor != null) {
          final owned = descriptor;
          descriptor = null;
          await _releaseDescriptor(owned);
        }
        if (sameListener()) _failDownload(event);
        return;
      }
      _provideDownload(event, descriptor == null ? path : null, descriptor);
      descriptor = null; // The isolate/native consumer now owns it.
    } catch (error, st) {
      if (descriptor != null) {
        try {
          await _releaseDescriptor(descriptor);
        } catch (releaseError, releaseStack) {
          _logger.warning('Failed to release unused browser source', releaseError, releaseStack);
        }
      }
      _logger.fine('Browser source ended before handoff', error, st);
      if (sameListener()) _failDownload(event);
    }
  }

  /// Core expiry/abort uses unique request IDs; never remove a newer peer session.
  void onPrepareDownloadAborted(HttpServerWebPrepareDownloadAbortedEvent event) {
    _removeSession(event.sessionId);
  }

  void _removeSession(String sessionId) {
    if (server.getStateOrNull()?.webDownloadState?.sessions.containsKey(sessionId) != true) return;
    server.setState(
      (old) => old?.updateWebDownloadState(
        (web) => web.copyWith(
          sessions: {
            for (final entry in web.sessions.entries)
              if (entry.key != sessionId) entry.key: entry.value,
          },
        ),
      ),
    );
  }

  Future<void> acceptRequest(String sessionId) => _answerRequest(sessionId, true);
  Future<void> declineRequest(String sessionId) => _answerRequest(sessionId, false);

  Future<void> _answerRequest(String sessionId, bool accept) async {
    final original = server.getStateOrNull()?.webDownloadState?.sessions[sessionId];
    if (original == null || !original.pending || _deciding.containsKey(sessionId)) return;
    _deciding[sessionId] = original;
    final listener = server.getListenerGeneration();
    try {
      await _sendDecision(sessionId, accept);
      // Expiry/closing/replacing the share may race the successful local reply.
      if (server.getListenerGeneration() != listener || !identical(server.getStateOrNull()?.webDownloadState?.sessions[sessionId], original)) return;
      if (!accept) {
        _removeSession(sessionId);
      } else {
        server.setState(
          (old) => old?.updateWebDownloadState(
            (web) => web.updateSession(
              sessionId: sessionId,
              update: (session) => session.copyWith(pending: false),
            ),
          ),
        );
      }
    } catch (error, st) {
      _logger.fine('Browser approval ended before the decision was applied', error, st);
      if (server.getListenerGeneration() == listener && identical(server.getStateOrNull()?.webDownloadState?.sessions[sessionId], original)) {
        _removeSession(sessionId);
      }
    } finally {
      if (identical(_deciding[sessionId], original)) _deciding.remove(sessionId);
    }
  }
}

/// Parses a human-readable device description from a user agent.
String parseDeviceInfoFromUserAgent(String? userAgent) {
  if (userAgent == null) {
    return 'Unknown';
  }

  final userAgentAnalyzer = UserAgentAnalyzer();
  final browser = userAgentAnalyzer.getBrowser(userAgent);
  final os = userAgentAnalyzer.getOS(userAgent);
  if (browser != null && os != null) {
    return '$browser ($os)';
  } else if (browser != null) {
    return browser;
  } else if (os != null) {
    return os;
  } else {
    return 'Unknown';
  }
}

extension on WebDownloadState {
  WebDownloadState updateSession({
    required String sessionId,
    required WebDownloadSession Function(WebDownloadSession oldSession) update,
  }) {
    return copyWith(
      sessions: {...sessions}
        ..update(
          sessionId,
          (session) => update(session),
        ),
    );
  }
}
