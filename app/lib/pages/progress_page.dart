import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:localsend_app/util/native_resume_strings.dart';
import 'package:localsend_app/util/notification_strings.dart';
import 'package:localsend_app/util/receive_session_lookup.dart';
import 'package:localsend_app/util/transfer_speed_label.dart';
import 'package:localsend_app/util/ui/nav_bar_padding.dart';
import 'package:localsend_app/util/ui/transfer_route.dart';
import 'package:localsend_app/util/ui/transfer_wake_lock.dart';
import 'package:localsend_app/widget/custom_progress_bar.dart';
import 'package:localsend_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_app/widget/receive_verification_tag.dart';
import 'package:localsend_app/widget/recovery_lifecycle_tag.dart';
import 'package:localsend_app/widget/transfer_activity_panel.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:localsend_isolates/util/file_speed_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// Extra space needed below the file list while the progress details are expanded.
const _advancedProgressPanelExtraPadding = 100.0;

class ProgressPage extends StatefulWidget {
  final bool showAppBar;
  final bool closeSessionOnClose;
  final String sessionId;
  final bool receiving;

  const ProgressPage({
    required this.showAppBar,
    required this.closeSessionOnClose,
    required this.sessionId,
    this.receiving = false,
  });

  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> with Refena {
  int _totalBytes = double.maxFinite.toInt();
  int _lastRemainingTimeUpdate = 0; // millis since epoch
  String? _remainingTime;
  List<FileDto> _files = []; // also contains declined files (files without token)
  Set<String> _selectedFiles = {};
  SessionStatus? _lastStatus;

  // If [autoFinish] is enabled, we wait a few seconds before automatically closing the session.
  int _finishCounter = 3;
  Timer? _finishTimer;
  TransferWakeLockLease? _wakeLease;

  bool _advanced = false;
  bool _identityBound = false;
  Object? _sendIdentity;
  int? _jobRevision, _listenerEpoch;

  void _bindIdentity() {
    if (_identityBound) return;
    _identityBound = true;
    if (widget.receiving) {
      _listenerEpoch = ref.notifier(serverProvider).listenerGeneration;
    } else {
      _sendIdentity = ref.notifier(sendProvider).sessionAttemptIdentity(widget.sessionId);
      _jobRevision = ref.read(sendQueueProvider).where((job) => job.id == widget.sessionId).firstOrNull?.attemptRevision;
    }
  }

  bool _sameAttempt() {
    if (!_identityBound) return true;
    if (widget.receiving) return _listenerEpoch == ref.notifier(serverProvider).listenerGeneration;
    final currentIdentity = ref.notifier(sendProvider).sessionAttemptIdentity(widget.sessionId);
    // Presentation identity survives cancellation but changes on a new attempt.
    // Even a replacement already canceled in this frame belongs to another page.
    if (!identical(_sendIdentity, currentIdentity)) return false;
    return _jobRevision == ref.read(sendQueueProvider).where((job) => job.id == widget.sessionId).firstOrNull?.attemptRevision;
  }

  /// On Android the foreground service keeps the process and the connection alive,
  /// so there is no reason to also keep the screen on.
  bool get _useWakelock => checkPlatformIsNot([TargetPlatform.android]);

  @override
  void initState() {
    super.initState();

    // init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sameAttempt()) return;
      if (ref.read(settingsProvider).autoFinish) {
        _finishTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!_sameAttempt()) {
            timer.cancel();
            closeTransferPage(context);
            return;
          }
          // an empty iterable (session already removed) also counts as finished
          final receive = (widget.receiving ? receiveSessionForId(ref.read(serverProvider)?.session, widget.sessionId) : null);
          final finished =
              (receive?.status ?? (widget.receiving ? null : ref.read(sendProvider)[widget.sessionId])?.status) == SessionStatus.finished;
          if (finished && ModalRoute.of(context)?.isCurrent == true) {
            if (_finishCounter == 1) {
              timer.cancel();
              _exit(closeSession: true);
            } else {
              setState(() {
                _finishCounter--;
              });
            }
          }
        });
      }

      setState(() {
        final receiveSession = (widget.receiving ? receiveSessionForId(ref.read(serverProvider)?.session, widget.sessionId) : null);
        if (receiveSession != null) {
          _files = receiveSession.files.values.map((f) => f.file).toList();
        } else {
          final sendSession = (widget.receiving ? null : ref.read(sendProvider)[widget.sessionId]);
          if (sendSession != null) {
            _files = sendSession.files.values.map((f) => f.file).toList();
          }
        }

        // We previously used f.token != null here, but this may not work on very fast networks.
        final transferNotifier = ref.read(fileTransferProvider);
        transferNotifier.registerFileSizes(widget.sessionId, {
          for (final file in _files) file.id: file.size,
        }, scope: widget.receiving ? TransferProgressScope.receive : TransferProgressScope.send);
        _selectedFiles = _files
            .where((f) => transferNotifier.getStatus(sessionId: widget.sessionId, fileId: f.id) != FileStatus.skipped)
            .map((f) => f.id)
            .toSet();

        _totalBytes = _files.where((f) => _selectedFiles.contains(f.id)).fold(0, (prev, curr) => prev + curr.size);
      });
    });
  }

  void _exit({required bool closeSession}) async {
    if (!_sameAttempt()) {
      closeTransferPage(context);
      return;
    }
    final receiveSession = (widget.receiving ? receiveSessionForId(ref.read(serverProvider)?.session, widget.sessionId) : null);
    final sendSession = (widget.receiving ? null : ref.read(sendProvider)[widget.sessionId]);
    final SessionStatus? status = receiveSession?.status ?? sendSession?.status;
    final keepSession = !closeSession;
    final result = status == null || keepSession || await _askCancelConfirmation(status);

    if (result && mounted) {
      closeTransferPage(context);
    }
  }

  Future<bool> _askCancelConfirmation(SessionStatus status) async {
    final receiveGeneration = widget.receiving ? ref.notifier(serverProvider).listenerGeneration : null;
    final sendAttempt = widget.receiving ? null : ref.notifier(sendProvider).sessionAttemptIdentity(widget.sessionId);
    final jobAttempt = widget.receiving ? null : ref.read(sendQueueProvider).where((job) => job.id == widget.sessionId).firstOrNull?.attemptRevision;
    final bool result = switch (status == SessionStatus.sending) {
      true => (await context.pushBottomSheet(() => const CancelSessionDialog())) == true,
      false => true,
    };
    if (!mounted) return false;
    if (result) {
      if (widget.receiving) {
        if (receiveGeneration != ref.notifier(serverProvider).listenerGeneration) return false;
      } else {
        if (!identical(sendAttempt, ref.notifier(sendProvider).sessionAttemptIdentity(widget.sessionId))) return false;
        final currentJobAttempt = ref.read(sendQueueProvider).where((job) => job.id == widget.sessionId).firstOrNull?.attemptRevision;
        if (jobAttempt != currentJobAttempt) return false;
      }
      final receiveSession = (widget.receiving ? receiveSessionForId(ref.read(serverProvider)?.session, widget.sessionId) : null);
      final sendState = (widget.receiving ? null : ref.read(sendProvider)[widget.sessionId]);

      if (receiveSession != null) {
        if (receiveSession.status == SessionStatus.sending) {
          ref.notifier(serverProvider).cancelSession(expectedSessionId: widget.sessionId);
        } else {
          ref.notifier(serverProvider).closeSession(expectedSessionId: widget.sessionId);
        }
      } else if (sendState != null) {
        if (sendState.status == SessionStatus.sending || (jobAttempt != null && sendState.status == SessionStatus.waiting)) {
          if (jobAttempt != null) {
            try {
              // Queue cancellation first persists the scoped source-end intent.
              // Never bypass it through the raw sender on a journal failure.
              await ref.notifier(sendQueueProvider).cancel(widget.sessionId);
            } catch (_) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.general.error)));
              return false;
            }
            if (!mounted) return false;
            final current = ref.read(sendQueueProvider).where((job) => job.id == widget.sessionId).firstOrNull;
            if (current != null && current.attemptRevision != jobAttempt) return false;
          } else {
            ref.notifier(sendProvider).cancelSession(widget.sessionId);
          }
        } else {
          ref.notifier(sendProvider).closeSession(widget.sessionId);
        }
      }
    }
    return result;
  }

  @override
  void dispose() {
    super.dispose();
    _finishTimer?.cancel();
    _wakeLease?.release();
    _wakeLease = null;
    TaskbarHelper.clearProgressBar(); // ignore: discarded_futures
  }

  @override
  Widget build(BuildContext context) {
    final resumeCopy = NativeResumeStrings(Translations.of(context).$meta.locale);
    Widget resumeInfo() => IconButton(
      key: const ValueKey('native-resume-info'),
      tooltip: resumeCopy.title,
      icon: const Icon(Icons.info_outline, size: 20),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(resumeCopy.title),
          content: SingleChildScrollView(child: Text(resumeCopy.explanation)),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.close))],
        ),
      ),
    );
    final transferNotifier = ref.watch(fileTransferProvider);
    final currBytes = transferNotifier.transferredBytes(
      widget.sessionId,
      scope: widget.receiving ? TransferProgressScope.receive : TransferProgressScope.send,
    );

    // No select: comparing the selected session runs the dart_mappable deep equality
    // over the whole files map on every state change.
    final receiveSession = (widget.receiving ? receiveSessionForId(ref.watch(serverProvider)?.session, widget.sessionId) : null);
    final sendSession = (widget.receiving ? null : ref.watch(sendProvider)[widget.sessionId]);

    if (!widget.receiving) {
      ref.watch(sendQueueProvider.select((jobs) => jobs.where((job) => job.id == widget.sessionId).firstOrNull?.attemptRevision));
    }
    _bindIdentity();
    final SessionState? commonSessionState = receiveSession ?? sendSession;

    final sameAttempt = _sameAttempt();
    final active = sameAttempt && (commonSessionState?.status == SessionStatus.waiting || commonSessionState?.status == SessionStatus.sending);
    if (_useWakelock && active) {
      _wakeLease ??= ref.read(transferWakeLockProvider).acquire();
    } else {
      _wakeLease?.release();
      _wakeLease = null;
    }

    if (commonSessionState == null || !sameAttempt) {
      // The session no longer exists, e.g. a multi-send session that finished successfully
      // in background gets removed while this page is still open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        closeTransferPage(context);
      });
      return Scaffold(
        body: Container(),
      );
    }

    final status = commonSessionState.status;

    if (status == SessionStatus.sending) {
      // ignore: discarded_futures
      TaskbarHelper.setProgressBar(currBytes, _totalBytes);
    } else if (status != _lastStatus) {
      _lastStatus = status;
      // ignore: discarded_futures
      TaskbarHelper.visualizeStatus(status);
    }

    final title = receiveSession != null ? t.progressPage.titleReceiving : t.progressPage.titleSending;
    final startTime = commonSessionState.startTime;
    final endTime = commonSessionState.endTime;
    final rates = ref.watch(transferSpeedProvider);
    final speedInBytes = status == SessionStatus.sending
        ? rates['${widget.receiving ? 'receive' : 'send'}:${widget.sessionId}']
        : status == SessionStatus.finished && startTime != null && endTime != null && endTime > startTime
        ? getFileSpeed(start: startTime, end: endTime, bytes: currBytes)
        : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (status == SessionStatus.sending && now - _lastRemainingTimeUpdate >= 1000) {
      _remainingTime = speedInBytes == null
          ? null
          : getRemainingTime(
              bytesPerSeconds: speedInBytes,
              remainingBytes: (_totalBytes - currBytes).clamp(0, _totalBytes),
              strings: notificationStrings,
            );
      _lastRemainingTimeUpdate = now;
    }

    final finishedCount = transferNotifier.statusCount(
      widget.sessionId,
      FileStatus.finished,
      scope: widget.receiving ? TransferProgressScope.receive : TransferProgressScope.send,
    );

    return PopScope(
      // Back only hides this route. Stopping a task is an explicit confirmed action.
      canPop: true,
      child: Scaffold(
        appBar: widget.showAppBar
            ? AppBar(
                title: Text(title),
                actions: [resumeInfo()],
              )
            : null,
        body: Stack(
          children: [
            ListView.builder(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 20,
                bottom: 175 + (_advanced ? _advancedProgressPanelExtraPadding : 0) + getNavBarPadding(context),
                left: 15,
                right: 30,
              ),
              itemCount: _files.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // title
                  if (widget.showAppBar) {
                    return Container();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                            resumeInfo(),
                          ],
                        ),
                        if (checkPlatformWithFileSystem() && receiveSession != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${t.settingsTab.receive.destination}: ',
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  TextSpan(
                                    text: receiveSession.destinationDirectory,
                                    style: TextStyle(
                                      color: checkPlatform([TargetPlatform.iOS]) ? Colors.grey : Theme.of(context).colorScheme.primary,
                                    ),
                                    recognizer: checkPlatform([TargetPlatform.iOS])
                                        ? null
                                        : (TapGestureRecognizer()
                                            ..onTap = () async {
                                              await openFolder(folderPath: receiveSession.destinationDirectory);
                                            }),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }

                if (index == 1) {
                  // error card
                  final errorMessage = sendSession?.errorMessage;
                  if (errorMessage == null) {
                    return Container();
                  }

                  return SelectableText(errorMessage, style: TextStyle(color: Theme.of(context).colorScheme.warning));
                }

                final file = _files[index - 2];
                final String fileName = receiveSession?.files[file.id]?.desiredName ?? file.fileName;

                final fileStatus = transferNotifier.getStatus(sessionId: widget.sessionId, fileId: file.id);
                final savedToGallery = receiveSession?.files[file.id]?.savedToGallery ?? false;
                final verification = transferNotifier.getVerification(sessionId: widget.sessionId, fileId: file.id);
                final recovery = transferNotifier.getRecovery(sessionId: widget.sessionId, fileId: file.id);

                final String? filePath;
                if (receiveSession != null && fileStatus == FileStatus.finished && !savedToGallery) {
                  filePath = receiveSession.files[file.id]!.path;
                } else if (sendSession != null) {
                  filePath = sendSession.files[file.id]!.path;
                } else {
                  filePath = null;
                }

                final String? errorMessage;
                if (receiveSession != null) {
                  errorMessage = receiveSession.files[file.id]!.errorMessage;
                } else if (sendSession != null) {
                  errorMessage = sendSession.files[file.id]!.errorMessage;
                } else {
                  errorMessage = null;
                }

                final Uint8List? thumbnail;
                final AssetEntity? asset;
                if (sendSession != null) {
                  thumbnail = sendSession.files[file.id]!.thumbnail;
                  asset = sendSession.files[file.id]!.asset;
                } else {
                  thumbnail = null;
                  asset = null;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: InkWell(
                    splashColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.transparent,
                    hoverColor: Colors.transparent,
                    onTap: filePath != null && receiveSession != null ? () async => openFile(context, file.fileType, filePath!) : null,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SmartFileThumbnail(
                          bytes: thumbnail,
                          asset: asset,
                          path: filePath,
                          fileType: file.fileType,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      fileName,
                                      style: const TextStyle(fontSize: 16, height: 1),
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                    ),
                                  ),
                                  Text(' (${file.size.asReadableFileSize})', style: const TextStyle(fontSize: 16, height: 1)),
                                ],
                              ),
                              const SizedBox(height: 5),
                              if (recovery != null) ...[RecoveryLifecycleTag(recovery: recovery), const SizedBox(height: 5)],
                              if (fileStatus == FileStatus.sending && verification != null)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ReceiveVerificationTag(verification: verification),
                                    const SizedBox(height: 5),
                                    LinearProgressIndicator(
                                      value: verification.progress,
                                      semanticsLabel: verification.receiving ? t.receivePage.verifyingReceivedData : t.sendPage.verifyingSourceData,
                                    ),
                                  ],
                                )
                              else if (fileStatus == FileStatus.sending)
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: CustomProgressBar(
                                    progress: transferNotifier.getProgress(sessionId: widget.sessionId, fileId: file.id),
                                  ),
                                )
                              else
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        savedToGallery ? t.progressPage.savedToGallery : fileStatus.label,
                                        style: TextStyle(color: fileStatus.getColor(context), height: 1),
                                      ),
                                    ),
                                    if (errorMessage != null) ...[
                                      const SizedBox(width: 5),
                                      InkWell(
                                        onTap: () async {
                                          await showDialog(
                                            context: context,
                                            builder: (_) => ErrorDialog(error: errorMessage!),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 5),
                                          child: Icon(Icons.info, color: Theme.of(context).colorScheme.warning, size: 20),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                            ],
                          ),
                        ),
                        if (sendSession != null &&
                            fileStatus == FileStatus.failed &&
                            recovery?.failure?.kind != UploadRecoveryFailureKind.sourceChanged)
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: t.sendQueue.singleFileRetryNewTask,
                            onPressed: sendSession.status != SessionStatus.finishedWithErrors || sendSession.sendingTasks?.isNotEmpty == true
                                ? null
                                : () async {
                                    if (!_sameAttempt()) return;
                                    try {
                                      final id = ref
                                          .notifier(sendQueueProvider)
                                          .retryFile(
                                            sessionId: widget.sessionId,
                                            file: sendSession.files[file.id]!,
                                          );
                                      if (id == null || !mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.sendQueue.singleFileRetryStarted)));
                                      await showModalBottomSheet<void>(
                                        context: context,
                                        isScrollControlled: true,
                                        builder: (_) => TransferActivityPanel(initialDirection: TransferDirection.send, initialTaskKey: 'send:$id'),
                                      );
                                    } catch (error) {
                                      if (!context.mounted) return;
                                      await showDialog<void>(
                                        context: context,
                                        builder: (_) => ErrorDialog(error: error.toString()),
                                      );
                                    }
                                  },
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 15, right: 15, bottom: 5, top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            status.getLabel(
                              remainingTime: _remainingTime ?? '-',
                            ),
                            style: const TextStyle(fontSize: 20),
                          ),
                          const SizedBox(height: 5),
                          TweenAnimationBuilder(
                            tween: Tween<double>(begin: 0, end: _totalBytes == 0 ? 0 : currBytes / _totalBytes),
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            builder: (context, value, child) {
                              return CustomProgressBar(
                                progress: value,
                                borderRadius: 5,
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          Text(
                            status == SessionStatus.finished
                                ? t.transferSpeed.average(speed: transferSpeedValue(speedInBytes))
                                : currentTransferSpeedLabel(status == SessionStatus.sending ? speedInBytes : 0),
                            key: const ValueKey('progress-transfer-speed'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          AnimatedCrossFade(
                            crossFadeState: _advanced ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 200),
                            alignment: Alignment.topLeft,
                            firstChild: Container(),
                            secondChild: Padding(
                              padding: const EdgeInsets.only(top: 10, bottom: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.progressPage.total.count(
                                      curr: finishedCount,
                                      n: _selectedFiles.length,
                                    ),
                                  ),
                                  Text(
                                    t.progressPage.total.size(
                                      curr: currBytes.asReadableFileSize,
                                      n: _totalBytes == double.maxFinite.toInt() ? '-' : _totalBytes.asReadableFileSize,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                                onPressed: () {
                                  setState(() => _advanced = !_advanced);
                                },
                                icon: const Icon(Icons.info),
                                label: Text(_advanced ? t.general.hide : t.general.advanced),
                              ),
                              IconButton(
                                tooltip: t.general.hide,
                                onPressed: () => _exit(closeSession: false),
                                icon: const Icon(Icons.expand_more),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                                onPressed: () => _exit(closeSession: true),
                                icon: Icon(status == SessionStatus.sending ? Icons.close : Icons.check_circle),
                                label: Text(
                                  status == SessionStatus.sending
                                      ? t.general.cancel
                                      : _finishTimer != null
                                      ? '${t.general.done} ($_finishCounter)'
                                      : t.general.done,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on FileStatus {
  String get label {
    switch (this) {
      case FileStatus.queue:
        return t.general.queue;
      case FileStatus.skipped:
        return t.general.skipped;
      case FileStatus.sending:
        return ''; // progress bar will be showed here
      case FileStatus.failed:
        return t.general.error;
      case FileStatus.finished:
        return t.general.done;
    }
  }

  Color getColor(BuildContext context) {
    switch (this) {
      case FileStatus.queue:
        return Theme.of(context).colorScheme.primary;
      case FileStatus.skipped:
        return Colors.grey;
      case FileStatus.sending:
        return Theme.of(context).colorScheme.primary;
      case FileStatus.failed:
        return Theme.of(context).colorScheme.warning;
      case FileStatus.finished:
        return Theme.of(context).colorScheme.primary;
    }
  }
}

extension on SessionStatus {
  String getLabel({required String remainingTime}) {
    switch (this) {
      case SessionStatus.sending:
        return t.progressPage.total.title.sending(
          time: remainingTime,
        );
      case SessionStatus.finished:
        return t.general.finished;
      case SessionStatus.finishedWithErrors:
        return t.progressPage.total.title.finishedError;
      case SessionStatus.canceledBySender:
        return t.progressPage.total.title.canceledSender;
      case SessionStatus.canceledByReceiver:
        return t.progressPage.total.title.canceledReceiver;
      default:
        return '';
    }
  }
}
