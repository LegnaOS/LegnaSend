import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/directory_upload_approval.dart';
import 'package:localsend_app/model/state/send/web/web_download_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/directory_publication_provider.dart';
import 'package:localsend_app/provider/directory_upload_approval_provider.dart';
import 'package:localsend_app/provider/integration_api_publication_provider.dart';
import 'package:localsend_app/provider/integration_api_settings_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/controller/send_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/provider/transfer_speed_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/provider/workspace_catalog_provider.dart';
import 'package:localsend_app/provider/workspace_content_provider.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/api/host_cache.dart';
import 'package:localsend_app/util/api/host_management.dart';
import 'package:localsend_app/util/api/host_native_tasks.dart';
import 'package:localsend_app/util/api/source_end_management.dart';
import 'package:localsend_app/util/api/transfer_management.dart';
import 'package:localsend_app/util/api/workspace_management.dart';
import 'package:localsend_app/util/api/workspace_send_capture.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/native/web_pages_loader.dart';
import 'package:localsend_app/util/network/transport_change.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/rust/api/server.dart' show WebI18n, WebMode, WebParams;
import 'package:localsend_isolates/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

typedef WebFilePublisher = Future<void> Function(Map<String, WebDownloadFile> additions, List<String> removals);
final webFilePublisherProvider = Provider<WebFilePublisher>(
  (ref) => (additions, removals) async {
    await ref
        .redux(parentIsolateProvider)
        .dispatchAsync(
          IsolateHttpServerPatchWorkspaceAction(
            files: {for (final entry in additions.entries) entry.key: entry.value.file.toRust()},
            removeFileIds: removals,
          ),
        );
  },
);

final _logger = Logger('Server');

/// This provider runs the server and provides the current server state.
/// It is a singleton provider, so only one server can be running at a time.
/// The server state is null if the server is not running.
/// The server can receive files (since v1) and send files (since v2).
///
/// The HTTP server itself runs in Rust (inside the server isolate); this
/// provider starts it, listens to its events and holds the resulting state.
final serverProvider = NotifierProvider<ServerService, ServerState?>((ref) => ServerService());

class ServerService extends Notifier<ServerState?> {
  late final _serverUtils = ServerUtils(
    refFunc: () => ref,
    getState: () => state!,
    getStateOrNull: () => state,
    setState: (builder) => state = builder(state),
    getListenerGeneration: () => _listenerGeneration,
  );

  late final _receiveController = ReceiveController(_serverUtils);
  late final _sendController = SendController(_serverUtils);

  StreamSubscription<HttpServerEvent>? _subscription;
  StreamSubscription<HttpServerEvent>? _pendingSubscription;
  StreamSubscription<HttpServerFileUploadResultEvent>? _receiptSubscription;
  StreamSubscription? _receiptParentSubscription;
  Object? _receiptConnection;
  Completer<int>? _pendingStartup;
  bool _disposed = false;
  int _managementActive = 0;
  bool? _listenerVerifyChecksums;
  late final _hostManagement = HostManagement(
    receiveCacheRetention: () => ref.read(receiveCacheRetentionProvider).snapshot(),
    pendingRestart: () => [
      if (state != null && state!.alias != ref.read(settingsProvider).alias) 'alias',
      if (state != null && _listenerVerifyChecksums != ref.read(settingsProvider).verifyChecksums) 'verifyChecksums',
    ],
    readSettings: () {
      final value = ref.read(settingsProvider);
      return {
        'alias': value.alias,
        'theme': value.theme.name,
        'locale': value.locale?.languageTag ?? 'system',
        'enableAnimations': value.enableAnimations,
        'autoFinish': value.autoFinish,
        'createChecksums': value.createChecksums,
        'verifyChecksums': value.verifyChecksums,
        'receiveCacheRetentionDays': value.receiveCacheRetentionDays,
      };
    },
    writeSetting: (field, value) async {
      final settings = ref.notifier(settingsProvider);
      switch (field) {
        case 'alias':
          await settings.setAlias((value as String).trim());
        case 'theme':
          await settings.setTheme(ThemeMode.values.byName(value as String));
        case 'locale':
          final locale = value == 'system' ? null : AppLocale.values.where((l) => l.languageTag == value).firstOrNull;
          if (value != 'system' && locale == null) throw const FormatException('Unsupported locale');
          await settings.setLocale(locale);
          if (locale == null) {
            await LocaleSettings.useDeviceLocale();
          } else {
            await LocaleSettings.setLocale(locale);
          }
        case 'enableAnimations':
          await settings.setEnableAnimations(value as bool);
        case 'autoFinish':
          await settings.setAutoFinish(value as bool);
        case 'createChecksums':
          await settings.setCreateChecksums(value as bool);
        case 'verifyChecksums':
          await settings.setVerifyChecksums(value as bool);
        case 'receiveCacheRetentionDays':
          final retention = ref.read(receiveCacheRetentionProvider);
          if (retention.busy) throw const HostSettingsBusy();
          if (!await retention.change(value as int)) throw StateError('Receive retention was not applied');
        default:
          throw const FormatException('Unsupported setting');
      }
    },
    cache: runHostCacheOperation,
  );

  StreamSubscription? _localRoutesSubscription;
  late final _transferManagement = _createTransferManagement();
  TransferManagement _createTransferManagement() {
    _localRoutesSubscription = ref.stream(localIpProvider).listen((_) => _transferManagement.refreshLocalRoutes());
    return TransferManagement(
      readDevices: () => ref.read(nearbyDevicesProvider).devices.values,
      readLocalAddresses: () => ref.read(localIpProvider).addresses,
      interfaceBinding: const [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.windows,
      ].contains(defaultTargetPlatform),
      enqueueRouted: (device, files, channel, route) => ref.notifier(sendQueueProvider).enqueueExplicit(device, files, channel, localRoute: route),
      enqueueOwnedRouted: (device, files, channel, route) {
        final epoch = generation;
        return ref
            .notifier(sendQueueProvider)
            .enqueueOwned(device, files, channel, localRoute: route, isCurrent: () => state != null && generation == epoch);
      },
      readSelection: () => ref.read(selectedSendingFilesProvider),
      readJobs: () => ref.read(sendQueueProvider),
      captureWorkspace: (workspaceId, workspaceGeneration, files) => _captureWorkspaceForSend(workspaceId, workspaceGeneration, files),
      captureDocumentWorkspace: (workspaceId, workspaceGeneration, files) =>
          _captureWorkspaceForSend(workspaceId, workspaceGeneration, files, documentSnapshot: true),
      enqueueCaptured: (device, captured, channel, route) => ref
          .notifier(sendQueueProvider)
          .enqueueOwned(
            device,
            captured.files,
            channel,
            localRoute: route,
            isCurrent: captured.isCurrent,
          ),
      enqueueOwned: (device, files, channel) {
        final epoch = generation;
        return ref.notifier(sendQueueProvider).enqueueOwned(device, files, channel, isCurrent: () => state != null && generation == epoch);
      },
      enqueue: (device, files, channel) => ref.notifier(sendQueueProvider).enqueueExplicit(device, files, channel),
      cancel: (id) => ref.notifier(sendQueueProvider).cancel(id),
      remove: (id) => ref.notifier(sendQueueProvider).removeAndWait(id),
      scan: () => ref.global.dispatchAsync(StartSmartScan()),
      readProgress: (id) {
        final activity = ref.read(transferActivityProvider).where((task) => task.id == id && task.job != null).firstOrNull;
        return (transferredBytes: activity?.transferredBytes ?? 0, bytesPerSecond: ref.read(transferSpeedProvider)['send:$id'] ?? 0);
      },
    );
  }

  Future<WorkspaceSendCapture> _captureWorkspaceForSend(
    String workspaceId,
    int workspaceGeneration,
    List<Map<String, String>> files, {
    bool documentSnapshot = false,
  }) async {
    final epoch = listenerGeneration;
    bool current() => state != null && listenerGeneration == epoch && ref.read(workspaceCatalogProvider).matches(workspaceId, workspaceGeneration);
    return captureWorkspaceSources(
      store: await ref.notifier(workspaceCaptureStoreProvider).ready(),
      fileCount: files.length,
      documentSnapshot: documentSnapshot,
      isCurrent: current,
      capture: (destination) => ref
          .redux(parentIsolateProvider)
          .dispatchAsyncTakeResult(
            IsolateHttpServerCaptureWorkspaceSourcesAction(
              workspaceId: workspaceId,
              generation: workspaceGeneration,
              files: encodeWorkspaceCaptureSelection(files, documentSnapshot: documentSnapshot),
              destination: destination,
            ),
          ),
    );
  }

  late final _sourceEndManagement = SourceEndManagement(
    read: () => ref.notifier(sourceEndProvider).redactedNotices(),
    retry: (id, version, requestId) => ref.notifier(sourceEndProvider).retry(id, version, requestId),
  );

  late final _nativeTasks = HostNativeTasks(
    readGeneration: () => generation,
    readTasks: () {
      final jobs = {for (final job in ref.read(sendQueueProvider)) job.id: job};
      final sends = ref.read(sendProvider);
      final receive = state?.session;
      final speeds = ref.read(transferSpeedProvider);
      final activities = ref
          .read(transferActivityProvider)
          .where(
            (task) =>
                task.kind == TransferActivityKind.native &&
                (task.direction == TransferDirection.receive
                    ? task.id == receive?.sessionId
                    : jobs.containsKey(task.id) || sends.containsKey(task.id)),
          )
          .toList();
      activities.sort((a, b) => (a.active ? 0 : 1).compareTo(b.active ? 0 : 1));
      return [
        for (final task in activities)
          HostNativeTask(
            activity: task,
            bytesPerSecond: speeds[task.key] ?? 0,
            controlRevision: task.direction == TransferDirection.receive
                ? (
                    task.phase,
                    receive?.startTime,
                    receive?.endTime,
                    receive?.destinationDirectory,
                    receive?.saveToGallery,
                    jsonEncode(ref.read(selectedReceivingFilesProvider)),
                  )
                : (
                    task.phase,
                    sends[task.id]?.startTime,
                    sends[task.id]?.endTime,
                    jobs[task.id]?.attemptIndices,
                    jobs[task.id]?.recoveryChecking,
                    jobs[task.id]?.attemptRevision,
                  ),
            actions: [
              if (task.active) ...[
                if (task.direction == TransferDirection.receive && task.phase == TransferPhase.waiting) ...['accept', 'reject'] else 'cancel',
              ] else if (jobs[task.id]?.restored != true && jobs[task.id]?.recoveryChecking != true)
                'remove',
            ],
          ),
      ];
    },
    control: (task, action) async {
      final activity = task.activity;
      if (activity.direction == TransferDirection.receive) {
        final current = state?.session;
        if (current == null || current.sessionId != activity.id) throw StateError('Receive task changed');
        switch (action) {
          case 'accept':
            await _receiveController.acceptFileRequest(
              current.message == null ? Map<String, String>.of(ref.read(selectedReceivingFilesProvider)) : {},
              expectedSessionId: activity.id,
            );
          case 'reject':
            _receiveController.declineFileRequest(expectedSessionId: activity.id);
          case 'cancel':
            _receiveController.cancelSession(expectedSessionId: activity.id);
          case 'remove':
            _receiveController.closeSession(expectedSessionId: activity.id);
        }
      } else {
        final queued = ref.read(sendQueueProvider).any((job) => job.id == activity.id);
        if (action == 'cancel') {
          if (queued) {
            await ref.notifier(sendQueueProvider).cancel(activity.id);
          } else {
            ref.notifier(sendProvider).cancelSession(activity.id);
          }
        } else if (action == 'remove') {
          if (queued) {
            await ref.notifier(sendQueueProvider).removeAndWait(activity.id);
          } else {
            ref.notifier(sendProvider).closeSession(activity.id);
          }
        }
      }
    },
  );
  final _lifecycle = AsyncSerialQueue();
  int _generation = 0;
  int get generation => _generation;

  // Keep listener lifetime separate: toggling a web share must not invalidate
  // an unrelated native receive operation waiting on a destination permission.
  int _listenerGeneration = 0;
  int get listenerGeneration => _listenerGeneration;
  final Stream<HttpServerEvent> Function(IsolateHttpServerStartAction)? _startListener;
  final Future<void> Function()? _stopListener;
  final Future<String?> Function()? _stopListenerWithActivity;
  final Future<Socket> Function(int port)? _probeListener;

  ServerService({
    Stream<HttpServerEvent> Function(IsolateHttpServerStartAction)? startListener,
    Future<void> Function()? stopListener,
    Future<String?> Function()? stopListenerWithActivity,
    Future<Socket> Function(int port)? probeListener,
  }) : _startListener = startListener,
       _stopListener = stopListener,
       _stopListenerWithActivity = stopListenerWithActivity,
       _probeListener = probeListener;

  @override
  ServerState? init() {
    return null;
  }

  /// Keep successful-save history independent of any one listener generation.
  /// Attach before starting a listener; stop/restart deliberately leaves it live.
  void _ensureReceiptSubscription() {
    if (_disposed) return;
    _receiptParentSubscription ??= ref.stream(parentIsolateProvider).listen(
      (_) {
        if (!_disposed) _bindReceiptConnection(ref.read(parentIsolateProvider));
      },
      onError: (Object error, StackTrace stack) => _logger.warning('Receive receipt connection failed', error, stack),
    );
    _bindReceiptConnection(ref.read(parentIsolateProvider));
  }

  void _bindReceiptConnection(ParentIsolateState parent) {
    if (_disposed || identical(_receiptConnection, parent.httpServer)) return;
    _receiptConnection = parent.httpServer;
    final previous = _receiptSubscription;
    _receiptSubscription = null;
    if (previous != null) {
      unawaited(previous.cancel().catchError((Object error) => _logger.warning('Failed to detach receive receipts', error)));
    }
    final connection = _receiptConnection;
    if (connection == null) return;
    _receiptSubscription = httpServerReceiveReceiptStream(parent).listen(
      (event) {
        if (_disposed || !identical(_receiptConnection, connection)) return;
        // Never send old results through _handleEvent: that path belongs to the
        // current listener and controls progress, notifications and navigation.
        unawaited(
          _receiveController.onReceiveReceipt(event).catchError((Object error, StackTrace stack) {
            _logger.warning('Failed to record receive receipt', error, stack);
          }),
        );
      },
      onError: (Object error, StackTrace stack) => _logger.warning('Receive receipt stream failed', error, stack),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listenerGeneration++;
    final pending = _pendingStartup;
    _pendingStartup = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('HTTP listener disposed during startup'));
    }
    final subscriptions = <StreamSubscription?>{
      _subscription,
      _pendingSubscription,
      _receiptSubscription,
      _receiptParentSubscription,
      _localRoutesSubscription,
    }..remove(null);
    _subscription = null;
    _pendingSubscription = null;
    _receiptSubscription = null;
    _receiptParentSubscription = null;
    _receiptConnection = null;
    for (final subscription in subscriptions) {
      unawaited(
        subscription!.cancel().catchError((Object error) {
          _logger.warning('Failed to detach disposed HTTP listener', error);
        }),
      );
    }
    super.dispose();
  }

  /// Transport advertisements are functional state, not debug observations.
  /// Refena 3.5.0 does not invoke provider onChanged in containers without
  /// diagnostic observers. Publish every transport state transition here,
  /// deduplicating session/progress-only updates before touching any isolate.
  @override
  set state(ServerState? value) {
    final previous = super.state;
    super.state = value;
    // File progress and approval updates do not change transport identity.
    if ((previous?.alias, previous?.port, previous?.https, previous != null, previous?.webDownloadState != null) ==
        (value?.alias, value?.port, value?.https, value != null, value?.webDownloadState != null)) {
      return;
    }
    final settings = ref.read(settingsProvider);
    final current = ref.read(parentIsolateProvider).syncState;
    final next = (
      value?.alias ?? settings.alias,
      value?.port ?? settings.port,
      (value?.https ?? settings.https) ? ProtocolType.https : ProtocolType.http,
      value != null,
      value?.webDownloadState != null,
    );
    if ((current.alias, current.port, current.protocol, current.serverRunning, current.download) == next) return;
    ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateSyncServerStateAction(
            alias: next.$1,
            port: next.$2,
            discoveryPort: settings.port,
            protocol: next.$3,
            serverRunning: next.$4,
            download: next.$5,
          ),
        );
  }

  /// The default (equality) strategy runs the dart_mappable deep equality which
  /// walks the whole files map on every change, making state updates O(n) per received file.
  @override
  bool updateShouldNotify(ServerState? prev, ServerState? next) => !identical(prev, next);

  /// The debug observer stringifies the state on every change,
  /// so large file maps must be summarized to keep transfers responsive in debug mode.
  @override
  String describeState(ServerState? state) {
    final session = state?.session;
    if (session == null || session.files.length <= 10) {
      return state.toString();
    }
    return state!.copyWith(session: session.copyWith(files: {})).toString().replaceFirst('files: {}', 'files: <${session.files.length} files>');
  }

  /// Starts the server from user settings.
  Future<ServerState?> startServerFromSettings() async {
    final settings = ref.read(settingsProvider);
    return startServer(
      alias: settings.alias,
      port: settings.port,
      https: settings.https,
    );
  }

  /// Starts the server.
  /// Passing a [web] share additionally serves the download page
  /// ([WebShareDownload], so web browsers can download the offered files)
  /// or the upload page ([WebShareUpload], so web browsers can upload files).
  Future<ServerState?> startServer({
    required String alias,
    required int port,
    required bool https,
    WebShareState? web,
  }) => _lifecycle.run(() => _startServer(alias: alias, port: port, https: https, web: web));

  Future<ServerState?> _startServer({
    required String alias,
    required int port,
    required bool https,
    WebShareState? web,
  }) async {
    if (_disposed) throw StateError('HTTP listener service is disposed');
    _ensureReceiptSubscription();
    if (state != null) {
      _logger.info('Server already running.');
      return null;
    }

    _generation++;
    final listenerGeneration = ++_listenerGeneration;
    alias = alias.trim();
    if (alias.isEmpty) {
      alias = generateRandomAlias();
    }

    if (port < 0 || port > 65535) {
      port = defaultPort;
    }

    _logger.info('Starting server...');

    // The server isolate derives its configuration from the sync state,
    // so it must be published before the start task.
    _syncServerState(alias: alias, port: port, https: https, serverRunning: false, download: web is WebShareDownload);

    final settings = ref.read(settingsProvider);
    // Custom pages provided by the user next to the executable, if any.
    // A custom error-403.html replaces the built-in 403 page even while no web
    // share is active; client certificates stay mandatory in that mode.
    final customWebPages = await loadCustomWebPages();
    if (_disposed || _listenerGeneration != listenerGeneration) throw StateError('HTTP listener startup expired');
    final startAction = IsolateHttpServerStartAction(
      pin: switch (web) {
        WebShareUpload(:final pin) => pin,
        _ => settings.receivePin,
      },
      verifyChecksums: settings.verifyChecksums,
      web: WebParams(
        mode: switch (web) {
          WebShareDownload(duplex: true, :final state, :final pin, :final allowUpload) => WebMode.duplex(
            files: {for (final entry in state.files.entries) entry.key: entry.value.file.toRust()},
            pin: pin,
            allowUpload: allowUpload,
          ),
          WebShareDownload(:final state, :final pin) => WebMode.download(
            files: {
              for (final entry in state.files.entries) entry.key: entry.value.file.toRust(),
            },
            pin: pin,
          ),
          WebShareUpload() => const WebMode.upload(),
          null => const WebMode.disabled(),
        },
        i18N: WebI18n(
          waiting: t.web.waiting,
          enterPin: t.web.enterPin,
          invalidPin: t.web.invalidPin,
          tooManyAttempts: t.web.tooManyAttempts,
          rejected: t.web.rejected,
          uploadRejected: t.sendPage.rejected,
          busy: t.sendPage.busy,
          files: t.web.files,
          fileName: t.web.fileName,
          size: t.web.size,
          dropHint: t.sendTab.placeItems,
          preview: t.webPreview.preview,
          closePreview: t.webPreview.closePreview,
          downloadOriginal: t.webPreview.downloadOriginal,
          previewLoading: t.webPreview.previewLoading,
          previewError: t.webPreview.previewError,
          previewUnsupported: t.webPreview.previewUnsupported,
          textPreview: {
            'encoding': t.webTextPreview.encoding,
            'auto': t.webTextPreview.auto,
            'previous': t.webTextPreview.previous,
            'next': t.webTextPreview.next,
            'more': t.webTextPreview.more,
            'retry': t.webTextPreview.retry,
            'indexed': t.webTextPreview.indexed,
            'lines': t.webTextPreview.lines,
            'section': t.webTextPreview.section,
            'complete': t.webTextPreview.complete,
            'loading': t.webTextPreview.loading,
            'view': t.webTextPreview.view,
            'range': t.webTextPreview.range,
            'changed': t.webTextPreview.changed,
            'decode': t.webTextPreview.decode,
            'failed': t.webTextPreview.failed,
            'unsupported': t.webTextPreview.unsupported,
            'hint': t.webTextPreview.hint,
            'wrap': t.webTextPreview.wrap,
            'numbers': t.webTextPreview.numbers,
            'search': t.webTextPreview.search,
            'searchScope': t.webTextPreview.searchScope,
            'loaded': t.webTextPreview.loaded,
            'full': t.webTextPreview.full,
            'find': t.webTextPreview.find,
            'stop': t.webTextPreview.stop,
            'caseSensitive': t.webTextPreview.caseSensitive,
            'previousMatch': t.webTextPreview.previousMatch,
            'nextMatch': t.webTextPreview.nextMatch,
            'matches': t.webTextPreview.matches,
            'scanned': t.webTextPreview.scanned,
            'searching': t.webTextPreview.searching,
            'searchDone': t.webTextPreview.searchDone,
            'searchStopped': t.webTextPreview.searchStopped,
            'noMatches': t.webTextPreview.noMatches,
            'searchLimit': t.webTextPreview.searchLimit,
            'clearSearch': t.webTextPreview.clearSearch,
            'rendered': t.webTextPreview.rendered,
            'source': t.webTextPreview.source,
            'markdownHint': t.webTextPreview.markdownHint,
            'markdownLimit': t.webTextPreview.markdownLimit,
            'markdownFailed': t.webTextPreview.markdownFailed,
          },
        ),
        pages: customWebPages,
      ),
      showToken: settings.showToken,
    );
    final Stream<HttpServerEvent> events =
        _startListener?.call(startAction) ?? ref.redux(parentIsolateProvider).dispatchTakeResult<Stream<HttpServerEvent>>(startAction);

    final started = Completer<int>();
    late final StreamSubscription<HttpServerEvent> subscription;
    subscription = events.listen(
      (event) {
        if (_listenerGeneration != listenerGeneration) return;
        if (event is HttpServerStartedEvent) {
          if (!started.isCompleted) {
            // Do not deliver a synchronous next event until state is published.
            subscription.pause();
            started.complete(event.port);
          }
          return;
        }
        if (!started.isCompleted) {
          subscription.pause();
          started.completeError(StateError('HTTP server event arrived before startup'));
          return;
        }
        _handleEvent(event);
      },
      onError: (Object error) {
        if (_listenerGeneration != listenerGeneration) return;
        if (!started.isCompleted) {
          subscription.pause();
          started.completeError(error);
        } else {
          _logger.severe('HTTP server error: $error');
        }
      },
      onDone: () {
        if (_listenerGeneration != listenerGeneration) return;
        if (!started.isCompleted) {
          started.completeError(StateError('HTTP server stopped before startup'));
        } else {
          unawaited(_restartDeadServer(expectedListenerGeneration: listenerGeneration));
        }
      },
    );

    _pendingStartup = started;
    _pendingSubscription = subscription;
    try {
      port = await started.future;
      if (_disposed || _listenerGeneration != listenerGeneration) throw StateError('HTTP listener startup expired');
    } catch (e) {
      if (_listenerGeneration == listenerGeneration) _listenerGeneration++;
      await subscription.cancel();
      if (!_disposed) _syncServerState(alias: alias, port: port, https: https, serverRunning: false, download: false);
      _logger.warning('Failed to start server', e);
      rethrow;
    } finally {
      if (identical(_pendingStartup, started)) _pendingStartup = null;
      if (identical(_pendingSubscription, subscription)) _pendingSubscription = null;
    }

    _subscription = subscription;

    final newServerState = ServerState(
      alias: alias,
      port: port,
      https: https,
      session: null,
      web: web,
    );

    _listenerVerifyChecksums = settings.verifyChecksums;
    state = newServerState;
    subscription.resume();
    ref
        .notifier(webTransferActivityProvider)
        .startPolling(
          generation: () => generation,
          isCurrent: () => identical(_subscription, subscription) && state != null,
        );
    _logger.info('Server started. (Port: $port, ${https ? 'HTTPS' : 'HTTP'} only)');
    return newServerState;
  }

  Future<bool> _listenerStopBarrier = Future<bool>.value(true);

  /// True only after the actual native stop acknowledgement. Consumers holding
  /// filesystem security scopes must retain them on failed/unknown shutdown.
  Future<bool> get listenerStopBarrier => _listenerStopBarrier;

  Future<void> stopServer() => _lifecycle.run(_stopServer);

  Future<void> _stopServer() async {
    if (_disposed) return;
    _generation++;
    _listenerGeneration++;
    _receiveController.onServerStopped();
    _sendController.onServerStopped();
    ref.notifier(directoryUploadApprovalProvider).abortAll();
    final stopGeneration = generation;
    final activities = ref.notifier(webTransferActivityProvider);
    activities.beginStop(generation: stopGeneration);
    _logger.info('Stopping server...');
    final subscription = _subscription;
    final stopBarrier = Completer<bool>();
    _listenerStopBarrier = stopBarrier.future;
    var released = false;
    _subscription = null;
    state = null;
    try {
      try {
        await subscription?.cancel();
      } finally {
        if (!_disposed) {
          String? finalSnapshot;
          try {
            if (_stopListenerWithActivity != null) {
              finalSnapshot = await _stopListenerWithActivity();
            } else if (_stopListener != null) {
              await _stopListener();
            } else {
              finalSnapshot = await ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerStopWithActivityAction());
            }
            released = true;
          } finally {
            if (!_disposed && generation == stopGeneration) {
              activities.stopped(generation: stopGeneration, finalSnapshot: finalSnapshot, observe: true);
            }
          }
        }
      }
    } finally {
      stopBarrier.complete(released);
    }
    _logger.info('Server stopped.');
  }

  /// One shared transport setting for native receiving, browser shares and API.
  Future<void> changeTransport({required int expectedGeneration, required bool https}) => _lifecycle.run(() async {
    if (generation != expectedGeneration) throw StateError('Server generation changed');
    final settings = ref.notifier(settingsProvider);
    final previous = settings.state.https;
    final current = state;
    final nextWeb = switch (current?.web) {
      WebShareDownload(:final state, :final pin, :final duplex, :final allowUpload) => WebShareDownload(
        state: state.copyWith(sessions: {}),
        pin: pin,
        duplex: duplex,
        allowUpload: allowUpload,
      ),
      final other => other,
    };
    await applyTransportChange(
      previous: previous,
      next: https,
      persist: settings.setHttps,
      apply: () async {
        if (current == null || current.https == https) return;
        await _stopServer();
        await _startServer(alias: current.alias, port: current.port, https: https, web: nextWeb);
      },
      restore: () async {
        if (current != null && state == null) {
          await _startServer(alias: current.alias, port: current.port, https: current.https, web: nextWeb);
        }
      },
    );
  });

  Future<ServerState?> restartServerFromSettings() async {
    final settings = ref.read(settingsProvider);
    return restartServer(alias: settings.alias, port: settings.port, https: settings.https);
  }

  Future<ServerState?> restartServer({
    required String alias,
    required int port,
    required bool https,
    WebShareState? web,
    int? expectedGeneration,
  }) => _lifecycle.run(() async {
    if (expectedGeneration != null && expectedGeneration != generation) return state;
    await _stopServer();
    return _startServer(alias: alias, port: port, https: https, web: web);
  });

  Future<void> acceptFileRequest(Map<String, String> fileNameMap, {String? expectedSessionId}) async {
    await _receiveController.acceptFileRequest(fileNameMap, expectedSessionId: expectedSessionId);
  }

  void declineFileRequest({String? expectedSessionId}) {
    _receiveController.declineFileRequest(expectedSessionId: expectedSessionId);
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory, {String? expectedSessionId}) {
    _receiveController.setSessionDestinationDir(destinationDirectory, expectedSessionId: expectedSessionId);
  }

  /// Updates the save to gallery setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery, {String? expectedSessionId}) {
    _receiveController.setSessionSaveToGallery(saveToGallery, expectedSessionId: expectedSessionId);
  }

  /// In addition to [closeSession], this method also cancels incoming requests.
  void cancelSession({String? expectedSessionId}) {
    _receiveController.cancelSession(expectedSessionId: expectedSessionId);
  }

  /// Clears the session.
  void closeSession({String? expectedSessionId}) {
    _receiveController.closeSession(expectedSessionId: expectedSessionId);
  }

  /// Restarts the server with web download (the download API) enabled for [files].
  /// The auto accept setting of a previous web download state is kept.
  Future<void> restartServerWithWebDownload({
    required String alias,
    required int port,
    required bool https,
    required List<CrossFile> files,
    String? pin,
    int? expectedGeneration,
    bool duplex = false,
    bool allowUpload = false,
  }) => ref.read(sourceCacheLeaseProvider).withLease(() async {
    final webDownloadState = await _sendController.buildWebDownloadState(files: files);
    await _lifecycle.run(() async {
      if (expectedGeneration != null && generation != expectedGeneration) throw StateError('Server generation changed');
      final web = WebShareDownload(state: webDownloadState, pin: pin, duplex: true, allowUpload: allowUpload);
      final current = state;
      if (current == null) {
        await _startServer(alias: alias, port: port, https: https, web: web);
        return;
      }
      // Routing is subordinate to the listener, not a mutually exclusive server mode.
      _generation++;
      state = current.copyWith(web: web);
      try {
        await ref
            .redux(parentIsolateProvider)
            .dispatchAsync(
              IsolateHttpServerSetWorkspaceAction(
                enabled: true,
                files: {for (final entry in webDownloadState.files.entries) entry.key: entry.value.file.toRust()},
                pin: pin,
                allowUpload: allowUpload,
              ),
            );
      } catch (_) {
        state = state?.copyWith(web: current.web);
        rethrow;
      }
    });
  });

  Future<String> integrationApiRequest({required int expectedGeneration, required String request}) async {
    if (generation != expectedGeneration || state == null) throw StateError('Server generation changed');
    // Never hold the lifecycle queue while waiting for a network response.
    final result = await ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerIntegrationAction(consoleRequest: request));
    if (generation != expectedGeneration || state == null) throw StateError('Server generation changed');
    return result;
  }

  Future<String> integrationApiControl({required int expectedGeneration, String? configuration}) => _lifecycle.run(() async {
    if (generation != expectedGeneration || state == null) throw StateError('Server generation changed');
    return ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerIntegrationAction(configuration: configuration));
  });

  Future<String> configureDirectoryWorkspaces({required int expectedGeneration, required String config}) => _lifecycle.run(() async {
    if (generation != expectedGeneration || state == null) throw StateError('Server generation changed');
    return ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateHttpServerDirectoryCatalogAction(config));
  });

  /// Append files and update only the permission for new browser requests.
  /// Never stop/rebind the server or replace previously published file IDs.
  Future<bool> updateWebWorkspace({required int expectedGeneration, List<CrossFile> files = const [], bool? allowUpload}) =>
      ref.read(sourceCacheLeaseProvider).withLease(() async {
        final added = await _sendController.buildWebDownloadState(files: files);
        return _lifecycle.run(() async {
          final current = state;
          final web = current?.web;
          if (generation != expectedGeneration || current == null || web is! WebShareDownload || !web.duplex) return false;
          final next = web.copyWith(
            state: web.state.copyWith(files: {...web.state.files, ...added.files}),
            allowUpload: allowUpload ?? web.allowUpload,
          );
          // Install targets before Rust makes the new IDs visible to a fast browser.
          state = current.copyWith(web: next);
          try {
            await ref
                .redux(parentIsolateProvider)
                .dispatchAsync(
                  IsolateHttpServerUpdateWorkspaceAction(
                    files: {for (final entry in added.files.entries) entry.key: entry.value.file.toRust()},
                    allowUpload: next.allowUpload,
                  ),
                );
          } catch (_) {
            // Keep receive progress updates made while the worker was applying the change.
            final live = state?.web;
            if (live is WebShareDownload) {
              final retained = Map.of(live.state.files)..removeWhere((id, _) => added.files.containsKey(id));
              state = state?.copyWith(
                web: live.copyWith(
                  state: live.state.copyWith(files: retained),
                  allowUpload: web.allowUpload,
                ),
              );
            }
            rethrow;
          }
          return true;
        });
      });

  /// File IDs are immutable; a replacement publishes a fresh ID and revokes the old one.
  Future<bool> patchWebFiles({required int expectedGeneration, required List<String> removeFileIds, List<CrossFile> replacements = const []}) => ref
      .read(sourceCacheLeaseProvider)
      .withLease(
        () => _lifecycle.run(() async {
          final current = state, web = state?.web;
          if (generation != expectedGeneration ||
              current == null ||
              web is! WebShareDownload ||
              !web.duplex ||
              removeFileIds.isEmpty ||
              removeFileIds.toSet().length != removeFileIds.length ||
              !removeFileIds.every(web.state.files.containsKey)) {
            return false;
          }
          final added = await _sendController.buildWebDownloadState(files: replacements);
          if (generation != expectedGeneration || state?.web is! WebShareDownload) return false;
          final live = state!.web as WebShareDownload;
          // Keep old sources resolvable until the core acknowledges cancellation; install new
          // sources before publishing their IDs to a fast browser. Never overwrite progress.
          state = state!.copyWith(
            web: live.copyWith(state: live.state.copyWith(files: {...live.state.files, ...added.files})),
          );
          try {
            await ref.read(webFilePublisherProvider)(added.files, removeFileIds);
          } catch (_) {
            if (generation == expectedGeneration && state?.web is WebShareDownload) {
              final now = state!.web as WebShareDownload;
              final retained = Map.of(now.state.files)..removeWhere((id, _) => added.files.containsKey(id));
              state = state!.copyWith(
                web: now.copyWith(state: now.state.copyWith(files: retained)),
              );
            }
            rethrow;
          }
          if (generation != expectedGeneration || state?.web is! WebShareDownload) return false;
          final now = state!.web as WebShareDownload;
          final retained = Map.of(now.state.files)..removeWhere((id, _) => removeFileIds.contains(id));
          state = state!.copyWith(
            web: now.copyWith(state: now.state.copyWith(files: retained)),
          );
          return true;
        }),
      );

  /// Explicitly ends only the still-current share after user confirmation.
  /// The generation is checked inside the serialized lifecycle, not just in the UI.
  Future<bool> stopWebShare({required int expectedGeneration}) => _lifecycle.run(() async {
    if (generation != expectedGeneration || state?.web == null) return false;
    await ref.redux(parentIsolateProvider).dispatchAsync(IsolateHttpServerSetWorkspaceAction(enabled: false));
    _generation++;
    state = state?.copyWith(web: null);
    return true;
  });

  Future<bool> updateWebSettings({required int expectedGeneration, bool? https, bool updatePin = false, String? pin}) => _lifecycle.run(() async {
    final current = state;
    final web = current?.web;
    if (generation != expectedGeneration || current == null || web == null) return false;
    final nextWeb = switch (web) {
      WebShareDownload(:final state, :final duplex, :final allowUpload) => WebShareDownload(
        duplex: duplex,
        allowUpload: allowUpload,
        state: state.copyWith(sessions: {}),
        pin: updatePin ? pin : web.pin,
      ),
      WebShareUpload() => WebShareUpload(pin: updatePin ? pin : web.pin),
    };
    if ((https == null || https == current.https) && nextWeb is WebShareDownload && nextWeb.duplex) {
      state = current.copyWith(web: nextWeb);
      try {
        await ref
            .redux(parentIsolateProvider)
            .dispatchAsync(
              IsolateHttpServerSetWorkspaceAction(
                enabled: true,
                files: {for (final entry in nextWeb.state.files.entries) entry.key: entry.value.file.toRust()},
                pin: nextWeb.pin,
                allowUpload: nextWeb.allowUpload,
              ),
            );
        _generation++;
        state = state?.copyWith();
      } catch (_) {
        state = state?.copyWith(web: current.web);
        rethrow;
      }
    } else {
      await _stopServer();
      await _startServer(alias: current.alias, port: current.port, https: https ?? current.https, web: nextWeb);
    }
    return true;
  });

  /// Changes temporary-share access without closing directory or native sessions.
  Future<void> setWebPin(String? pin) async {
    if (state?.web == null || state!.web!.pin == pin) return;
    await updateWebSettings(expectedGeneration: generation, updatePin: true, pin: pin);
  }

  /// Updates the auto accept setting for web download.
  void setWebDownloadAutoAccept(bool autoAccept) {
    state = state?.updateWebDownloadState((webDownload) => webDownload.copyWith(autoAccept: autoAccept));
  }

  /// Accepts the web download request.
  void acceptWebDownloadRequest(String sessionId) {
    unawaited(_sendController.acceptRequest(sessionId));
  }

  /// Declines the web download request.
  void declineWebDownloadRequest(String sessionId) {
    unawaited(_sendController.declineRequest(sessionId));
  }

  Future<void> _handleWorkspaceManagement(HttpServerWorkspaceManagementEvent event) async {
    final epoch = generation;
    Future<String> control([String? response]) => ref
        .redux(parentIsolateProvider)
        .dispatchAsyncTakeResult(
          IsolateHttpServerWorkspaceManagementAction(requestId: event.requestId, response: response),
        );
    // A stalled platform store must not permit an unbounded host queue after HTTP deadlines.
    if (_managementActive >= 16) {
      try {
        await control('{"status":503,"body":{"error":{"code":"workspace_management_busy"}}}');
      } catch (_) {}
      return;
    }
    _managementActive++;
    try {
      Future<bool> claim() async {
        if (state == null || generation != epoch) return false;
        final accepted = await control() == 'true';
        return accepted && state != null && generation == epoch;
      }

      final request = jsonDecode(event.request);
      final operation = request is Map ? request['operation'] : null;
      if (operation is String && operation.startsWith('keys.')) {
        await control(
          await ref
              .notifier(integrationApiSettingsProvider)
              .manageKeys(
                request: event.request,
                claim: claim,
                publish: () async {
                  await ref.notifier(integrationApiPublicationProvider).synchronize();
                  final saved = ref.read(integrationApiSettingsProvider);
                  final publication = ref.read(integrationApiPublicationProvider);
                  return state != null && generation == epoch && !publication.failed && publication.appliedGeneration == saved.generation;
                },
              ),
        );
        return;
      }
      if (operation == 'nativeTasks.sourceEndList' || operation == 'nativeTasks.sourceEndRetry') {
        await control(await _sourceEndManagement.execute(request: event.request, claim: claim));
        return;
      }
      if (operation is String && operation.startsWith('nativeTasks.')) {
        await control(await _nativeTasks.execute(request: event.request, claim: claim));
        return;
      }
      if (operation is String && operation.startsWith('host.')) {
        await control(await _hostManagement.execute(request: event.request, claim: claim));
        return;
      }
      if (operation is String && operation.startsWith('transfer.')) {
        await control(await _transferManagement.execute(request: event.request, claim: claim));
        return;
      }
      final result = await executeWorkspaceManagement(
        catalog: ref.notifier(workspaceCatalogProvider).catalog,
        request: event.request,
        claim: claim,
        publish: () async {
          if (state == null || generation != epoch) throw StateError('Listener changed');
          await ref.notifier(directoryPublicationProvider).synchronize();
          final publication = ref.read(directoryPublicationProvider);
          final expected = ref.read(workspaceCatalogProvider).publishable.toList();
          if (state == null ||
              generation != epoch ||
              publication.failed ||
              publication.busy ||
              publication.published.length != expected.length ||
              expected.any((entry) => publication.published[entry.id] != entry.generation)) {
            throw StateError('Workspace publication is pending');
          }
        },
      );
      await control(result);
    } catch (_) {
      // No paths, source references, keys or request bodies in error logs.
      try {
        await control('{"status":503,"body":{"error":{"code":"workspace_management_unavailable"}}}');
      } catch (_) {}
    } finally {
      _managementActive--;
    }
  }

  Future<void> _handleDirectoryContent(HttpServerDirectoryContentEvent event) async {
    final listener = listenerGeneration;
    String? response;
    try {
      response = await ref.notifier(workspaceContentProvider).observe(event.request, expectedListener: listener);
    } catch (_) {
      // Failure is explicit: core keeps unknown rather than publishing an uncommitted counter.
    }
    if (_disposed || state == null || listenerGeneration != listener) return;
    try {
      await ref
          .redux(parentIsolateProvider)
          .dispatchAsyncTakeResult(
            IsolateHttpServerDirectoryContentAction(requestId: event.requestId, response: response),
          );
    } catch (_) {
      // The old core request may already have expired or the listener may have stopped.
    }
  }

  void _handleEvent(HttpServerEvent event) {
    switch (event) {
      case HttpServerWebDownloadActivityEvent():
        ref.notifier(webTransferActivityProvider).apply(event.snapshot, generation: generation);
      case HttpServerDirectoryUploadApprovalEvent():
        final epoch = generation;
        try {
          final data = jsonDecode(event.request) as Map<String, dynamic>;
          if (data['requestId'] != event.requestId) throw const FormatException('Approval ID mismatch');
          final request = DirectoryUploadApproval(
            requestId: event.requestId,
            workspaceId: data['workspaceId'] as String,
            workspaceName: data['workspaceName'] as String,
            peerIp: data['peerIp'] as String,
            expiresAt: data['expiresAt'] as int,
            files: (data['files'] as List)
                .map(
                  (entry) => DirectoryUploadApprovalFile(
                    path: entry['path'] as String,
                    size: entry['size'] as int,
                    directory: entry['directory'] as bool,
                  ),
                )
                .toList(growable: false),
          );
          ref
              .notifier(directoryUploadApprovalProvider)
              .add(
                request,
                respond: (accept) async {
                  if (epoch != generation) throw StateError('Approval server changed');
                  final answered = await ref
                      .redux(parentIsolateProvider)
                      .dispatchAsyncTakeResult(
                        IsolateHttpServerDirectoryUploadApprovalAction(requestId: event.requestId, accept: accept),
                      );
                  if (!answered || epoch != generation) throw StateError('Approval expired');
                },
              );
        } catch (_) {
          _logger.warning('Invalid directory upload approval metadata');
        }
      case HttpServerDirectoryUploadApprovalAbortedEvent():
        ref.notifier(directoryUploadApprovalProvider).aborted(event.requestId);
      case HttpServerDirectoryContentEvent():
        unawaited(_handleDirectoryContent(event));
      case HttpServerWorkspaceManagementEvent():
        unawaited(_handleWorkspaceManagement(event));
      case HttpServerDirectoryCatalogResult():
      case HttpServerIntegrationResult():
        // Scoped task acknowledgements are consumed by the parent action.
        break;
      case HttpServerStartedEvent():
        break;
      case HttpServerRegisterEvent():
        // ignore: discarded_futures
        _receiveController.onRegister(event);
      case HttpServerReceiveDestinationErrorEvent():
        _receiveController.onDestinationUnavailable(event);
      case HttpServerPrepareUploadEvent():
        // ignore: discarded_futures
        _receiveController.onPrepareUpload(event);
      case HttpServerFileUploadEvent():
        _receiveController.onFileUpload(event);
      case HttpServerFileUploadProgressEvent():
        _receiveController.onFileUploadProgress(event);
      case HttpServerFileVerificationEvent():
        _receiveController.onFileVerification(event);
      case HttpServerFileUploadResultEvent():
        // ignore: discarded_futures
        _receiveController.onFileUploadResult(event);
      case HttpServerSessionEndEvent():
        _receiveController.onSessionEnd(event);
      case HttpServerPrepareUploadAbortedEvent():
        _receiveController.onPrepareUploadAborted(event);
      case HttpServerCancelReceivedEvent():
        _receiveController.onCancelReceived(event);
      case HttpServerShowEvent():
        _receiveController.onShow(event);
      case HttpServerWebPrepareDownloadEvent():
        _sendController.onPrepareDownload(event);
      case HttpServerWebPrepareDownloadAbortedEvent():
        _sendController.onPrepareDownloadAborted(event);
      case HttpServerWebFileDownloadEvent():
        // ignore: discarded_futures
        _sendController.onFileDownload(event);
      case HttpServerListenerFailedEvent():
        // ignore: discarded_futures
        _restartAfterListenerFailure(event.error);
    }
  }

  /// Restarts the server after its listening socket failed permanently,
  /// e.g. because iOS reclaimed it while the app was suspended.
  /// The Rust server has already stopped itself at this point.
  Future<void> _restartAfterListenerFailure(String error) async {
    _logger.warning('The server listener failed: $error. Restarting server.');
    await _restartDeadServer(expectedListenerGeneration: _listenerGeneration);
  }

  bool _probeInFlight = false;

  /// Restarts the server when it no longer accepts a loopback probe connection, e.g. because iOS invalidated the socket while the app was suspended.
  Future<void> ensureRunning() async {
    if (_disposed) return;
    final current = state;
    if (current == null || _probeInFlight) {
      return;
    }

    _probeInFlight = true;
    final listenerGeneration = _listenerGeneration;
    try {
      final socket =
          await (_probeListener?.call(current.port) ??
              Socket.connect(
                InternetAddress.loopbackIPv4,
                current.port,
                timeout: const Duration(seconds: 1),
              ));
      socket.destroy();
    } catch (e) {
      _logger.warning('The server did not accept a probe connection: $e. Restarting server.');
      await _restartDeadServer(expectedListenerGeneration: listenerGeneration);
    } finally {
      _probeInFlight = false;
    }
  }

  /// Restarts the server with its current configuration after its listening socket died.
  Future<void> _restartDeadServer({required int expectedListenerGeneration}) async {
    try {
      await _lifecycle.run(() async {
        // A probe or listener callback may have waited behind a user restart.
        // Recheck inside the queue, not only before enqueuing the operation.
        if (_listenerGeneration != expectedListenerGeneration) return;
        final current = state;
        if (current == null) return;
        await _stopServer();
        await _startServer(
          alias: current.alias,
          port: current.port,
          https: current.https,
          web: switch (current.web) {
            WebShareDownload(:final state, :final pin, :final duplex, :final allowUpload) => WebShareDownload(
              duplex: duplex,
              allowUpload: allowUpload,
              state: state.copyWith(sessions: {}),
              pin: pin,
            ),
            final other => other,
          },
        );
      });
    } catch (e) {
      _logger.severe('Failed to restart the server after its listener failed', e);
    }
  }

  void _syncServerState({
    required String alias,
    required int port,
    required bool https,
    required bool serverRunning,
    required bool download,
  }) {
    ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateSyncServerStateAction(
            alias: alias,
            port: port,
            discoveryPort: ref.read(settingsProvider).port,
            protocol: https ? ProtocolType.https : ProtocolType.http,
            serverRunning: serverRunning,
            download: download,
          ),
        );
  }
}
