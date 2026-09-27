import 'dart:async';

import 'package:flutter/services.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/src/isolate/child/http_provider.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/src/task/upload/http_upload.dart';
import 'package:localsend_isolates/util/android_channel.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/source_end.dart';
import 'package:localsend_isolates/util/upload_recovery.dart';
import 'package:localsend_isolates/util/upload_scheduler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:typed_isolates/typed_isolates.dart';

/// Cross-task permits belong to the isolate, not to one peer or send session.
final _uploadSchedulerProvider = Provider((ref) => UploadScheduler());

/// How often a single file is uploaded at most when the receiver keeps
/// rejecting it with a checksum mismatch (HTTP 422).
/// Must not exceed MAX_UPLOAD_ATTEMPTS of the Rust server which stops
/// accepting retries at some point.
const _maxUploadAttempts = 3;

sealed class BaseHttpUploadTask {}

class HttpUploadFile {
  final String remoteFileToken;
  final String fileId;
  final String? resumeKey;
  final bool enableSourceEnd;
  final String? filePath;
  final List<int>? fileBytes;
  final int fileSize;

  HttpUploadFile({
    required this.remoteFileToken,
    required this.fileId,
    this.resumeKey,
    this.enableSourceEnd = false,
    required this.filePath,
    required this.fileBytes,
    required this.fileSize,
  });
}

/// Uploads a list of files as one isolate task.
///
/// This task is intended to replace the file scheduling loop in the parent
/// isolate. [UploadScheduler] bounds small/large files and all active tasks;
/// progress is reported across the complete list.
class HttpUploadFilesTask implements BaseHttpUploadTask {
  final String? remoteSessionId;
  final List<HttpUploadFile> files;
  final Device device;
  final LocalSendRoute? localRoute;

  HttpUploadFilesTask({
    required this.remoteSessionId,
    required this.files,
    required this.device,
    this.localRoute,
  });
}

class HttpUploadCancelTask implements BaseHttpUploadTask {
  final int taskId;

  HttpUploadCancelTask({required this.taskId});
}

class HttpSourceEndTask implements BaseHttpUploadTask {
  final Device target;
  final LocalSendRoute? localRoute;
  final SourceEndGrant grant;
  final String requestId;
  HttpSourceEndTask({required this.target, required this.localRoute, required this.grant, required this.requestId});
  @override
  String toString() => 'HttpSourceEndTask(redacted)';
}

class HttpSourceEndAckTask implements BaseHttpUploadTask {
  final int uploadTaskId;
  final String fileId, ackId;
  final bool persisted;
  HttpSourceEndAckTask({required this.uploadTaskId, required this.fileId, required this.ackId, required this.persisted});
}

class HttpUploadSourceEndGrantEvent extends HttpUploadEvent {
  final String ackId;
  final SourceEndGrant grant;
  HttpUploadSourceEndGrantEvent({required super.fileId, required this.ackId, required this.grant});
  @override
  String toString() => 'HttpUploadSourceEndGrantEvent(redacted)';
}

class HttpUploadSourceEndUnavailableEvent extends HttpUploadEvent {
  HttpUploadSourceEndUnavailableEvent({required super.fileId});
}

class HttpSourceEndResultEvent extends HttpUploadEvent {
  final SourceEndResult? result;
  HttpSourceEndResultEvent(this.result) : super(fileId: '');
}

final _sourceEndAcks = Provider((ref) => <String, ({int task, String file, RsHttpClient client})>{});

/// A message sent from the upload isolate to the main isolate
/// reporting the state of a single file of a [HttpUploadFilesTask].
sealed class HttpUploadEvent {
  final String fileId;

  HttpUploadEvent({required this.fileId});
}

/// The upload of the file has started.
class HttpUploadFileStartedEvent extends HttpUploadEvent {
  HttpUploadFileStartedEvent({required super.fileId});
}

/// The upload progress of the file in the range [0, 1].
class HttpUploadFileProgressEvent extends HttpUploadEvent {
  final double progress;

  HttpUploadFileProgressEvent({
    required super.fileId,
    required this.progress,
  });
}

/// The file has been uploaded successfully.
class HttpUploadFileFinishedEvent extends HttpUploadEvent {
  HttpUploadFileFinishedEvent({required super.fileId});
}

class HttpUploadFileVerificationEvent extends HttpUploadEvent {
  final int verifiedBytes;
  final int totalBytes;
  HttpUploadFileVerificationEvent({required super.fileId, required this.verifiedBytes, required this.totalBytes});
}

class HttpUploadFileRecoveryEvent extends HttpUploadEvent {
  final bool waiting;
  final int attempt;
  final int retryAfterMs;
  HttpUploadFileRecoveryEvent({required super.fileId, required this.waiting, required this.attempt, required this.retryAfterMs});
}

/// The upload of the file has failed. The next file is still uploaded.
class HttpUploadFileFailedEvent extends HttpUploadEvent {
  final String error;
  final bool? retainedConfirmed;
  final UploadRecoveryFailure? recovery;

  HttpUploadFileFailedEvent({
    required super.fileId,
    required this.error,
    this.retainedConfirmed,
    this.recovery,
  });
}

/// Map of cancel tokens for each task.
/// Task ID -> CancelToken
final _cancelTokenProvider = Provider((ref) => <int, RsCancellationToken>{});

Future<void> setupHttpUploadIsolate(
  Stream<SendToIsolateData<IsolateTask<BaseHttpUploadTask>>> receiveFromMain,
  void Function(IsolateTaskStreamResult<HttpUploadEvent>) sendToMain,
  InitialData initialData,
) async {
  await setupChildIsolateHelper(
    debugLabel: 'HttpUploadIsolate',
    receiveFromMain: receiveFromMain,
    sendToMain: sendToMain,
    initialData: initialData,
    init: (ref) async {
      // Initialize the platform method channel so getFileDescriptorAndroid
      // (used to resolve "content://" files) works inside this isolate.
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        ref.read(syncProvider).rootIsolateToken as RootIsolateToken,
      );
    },
    handler: (ref, task) async {
      final HttpUploadFilesTask uploadTask;
      switch (task.data) {
        case HttpUploadFilesTask task:
          uploadTask = task;
          break;
        case HttpSourceEndAckTask ack:
          final pending = ref.read(_sourceEndAcks)[ack.ackId];
          if (pending != null && pending.task == ack.uploadTaskId && pending.file == ack.fileId) {
            ref.read(_sourceEndAcks).remove(ack.ackId);
            pending.client.ackSourceEndGrant(ackId: ack.ackId, persisted: ack.persisted);
          }
          return;
        case HttpSourceEndTask end:
          final token = createCancellationToken();
          ref.read(_cancelTokenProvider)[task.id] = token;
          final timer = Timer(const Duration(seconds: 12), token.cancel);
          SourceEndResult? result;
          try {
            final client = ref.read(httpProvider).pinnedTo(end.target.fingerprint, timeoutMs: 12000, localRoute: end.localRoute);
            // Refresh the original identity before sending a scoped bearer grant.
            // TLS also pins at handshake; HTTP is not cryptographic peer proof.
            final identity = await client.register(
              protocol: end.target.getProtocolType(),
              ip: end.target.ip!,
              port: end.target.port,
              payload: ref.read(syncProvider).toRegisterDto(),
            );
            if (identity.body.token.toUpperCase() != end.target.fingerprint.toUpperCase()) throw StateError('peerChanged');
            result = decodeSourceEndResult(
              await client.endSource(
                protocol: end.target.getProtocolType(),
                ip: end.target.ip!,
                port: end.target.port,
                publicKey: null,
                grant: encodeSourceEndGrant(end.grant),
                requestId: end.requestId,
                cancelToken: token,
              ),
            );
          } catch (_) {
            /* Unknown transport outcome, never a deletion claim. */
          } finally {
            timer.cancel();
            ref.read(_cancelTokenProvider).remove(task.id);
          }
          sendToMain(IsolateTaskStreamResult.event(id: task.id, data: HttpSourceEndResultEvent(result)));
          sendToMain(IsolateTaskStreamResult.done(id: task.id));
          return;
        case HttpUploadCancelTask task:
          final cancelToken = ref.read(_cancelTokenProvider)[task.taskId];
          cancelToken?.cancel();
          ref.read(_cancelTokenProvider).remove(task.taskId);
          return;
      }

      // One client for the whole task: pinned to the receiver, so no file
      // content can be streamed to a different peer, and shared by all files
      // of the task so the connection is reused.
      final RsHttpClient client;
      try {
        client = ref.read(httpProvider).pinnedTo(uploadTask.device.fingerprint, localRoute: uploadTask.localRoute);
      } catch (error) {
        // A selected interface can disappear after prepare-upload. Report the
        // binding failure for this task instead of hanging its stream or using
        // an automatic-route client with a different network path.
        for (final file in uploadTask.files) {
          sendToMain(
            IsolateTaskStreamResult.event(
              id: task.id,
              data: HttpUploadFileFailedEvent(fileId: file.fileId, error: error.humanErrorMessage),
            ),
          );
        }
        sendToMain(IsolateTaskStreamResult.done(id: task.id));
        return;
      }

      final cancelToken = createCancellationToken();
      ref.read(_cancelTokenProvider).putIfAbsent(task.id, () => cancelToken);
      try {
        await ref
            .read(_uploadSchedulerProvider)
            .run<HttpUploadFile>(
              uploadTask.files,
              sizeOf: (file) => file.fileSize,
              isCancelled: () => !ref.read(_cancelTokenProvider).containsKey(task.id),
              upload: (file) async {
                sendToMain(
                  IsolateTaskStreamResult.event(
                    id: task.id,
                    data: HttpUploadFileStartedEvent(fileId: file.fileId),
                  ),
                );

                try {
                  final filePath = file.filePath;
                  final isContentUri = filePath?.startsWith('content://') ?? false;

                  for (var attempt = 1; ; attempt++) {
                    // The file descriptor is consumed by the upload, so a fresh one
                    // is needed for every attempt.
                    final fileDescriptor = isContentUri ? await getFileDescriptorAndroid(uri: filePath!) : null;

                    try {
                      await ref
                          .read(httpUploadProvider)
                          .upload(
                            client: client,
                            stream: filePath == null && file.fileBytes != null ? Stream.value(file.fileBytes!) : null,
                            path: !isContentUri ? filePath : null,
                            fileDescriptor: fileDescriptor,
                            contentLength: file.fileSize,
                            target: uploadTask.device,
                            remoteSessionId: uploadTask.remoteSessionId,
                            fileId: file.fileId,
                            token: file.remoteFileToken,
                            resumeKey: file.resumeKey,
                            enableSourceEnd: file.enableSourceEnd,
                            onSourceEndGrant: (ackId, grant) {
                              if (ref.read(_sourceEndAcks).length >= 16) {
                                client.ackSourceEndGrant(ackId: ackId, persisted: false);
                                return;
                              }
                              ref.read(_sourceEndAcks)[ackId] = (task: task.id, file: file.fileId, client: client);
                              sendToMain(
                                IsolateTaskStreamResult.event(
                                  id: task.id,
                                  data: HttpUploadSourceEndGrantEvent(fileId: file.fileId, ackId: ackId, grant: grant),
                                ),
                              );
                            },
                            onSourceEndUnavailable: () => sendToMain(
                              IsolateTaskStreamResult.event(
                                id: task.id,
                                data: HttpUploadSourceEndUnavailableEvent(fileId: file.fileId),
                              ),
                            ),
                            onRecovery: (waiting, attempt, retryAfterMs) => sendToMain(
                              IsolateTaskStreamResult.event(
                                id: task.id,
                                data: HttpUploadFileRecoveryEvent(
                                  fileId: file.fileId,
                                  waiting: waiting,
                                  attempt: attempt,
                                  retryAfterMs: retryAfterMs,
                                ),
                              ),
                            ),
                            onVerification: (verified, total) => sendToMain(
                              IsolateTaskStreamResult.event(
                                id: task.id,
                                data: HttpUploadFileVerificationEvent(fileId: file.fileId, verifiedBytes: verified, totalBytes: total),
                              ),
                            ),
                            onSendProgress: (progress) {
                              sendToMain(
                                IsolateTaskStreamResult.event(
                                  id: task.id,
                                  data: HttpUploadFileProgressEvent(
                                    fileId: file.fileId,
                                    progress: progress,
                                  ),
                                ),
                              );
                            },
                            cancelToken: cancelToken,
                          );
                      break;
                    } on RsHttpClientError_StatusCode catch (e) {
                      if (e.status != 422 || attempt >= _maxUploadAttempts) {
                        rethrow;
                      }
                      // The receiver discarded the file because its checksum did not
                      // match (e.g. the file changed while being read). Send it again.
                    }
                  }

                  sendToMain(
                    IsolateTaskStreamResult.event(
                      id: task.id,
                      data: HttpUploadFileFinishedEvent(fileId: file.fileId),
                    ),
                  );
                } catch (e) {
                  final recovery = classifyUploadRecovery(e);
                  sendToMain(
                    IsolateTaskStreamResult.event(
                      id: task.id,
                      data: HttpUploadFileFailedEvent(
                        fileId: file.fileId,
                        error: e.humanErrorMessage,
                        retainedConfirmed: recovery?.retainedConfirmed,
                        recovery: recovery,
                      ),
                    ),
                  );
                }
              },
            );

        sendToMain(
          IsolateTaskStreamResult.done(
            id: task.id,
          ),
        );
      } finally {
        final pending = ref.read(_sourceEndAcks);
        for (final entry in pending.entries.where((e) => e.value.task == task.id).toList()) {
          pending.remove(entry.key);
          entry.value.client.ackSourceEndGrant(ackId: entry.key, persisted: false);
        }
        ref.read(_cancelTokenProvider).remove(task.id);
      }
    },
  );
}
