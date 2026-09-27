import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/util/native/ios_drop_channel.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_isolates/util/logger.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

final _logger = Logger('ClearCacheAction');

// file_picker 11.0.3 on iOS deletes all of NSTemporaryDirectory, not just
// picker-owned files. Never invoke that platform's blanket implementation.
bool supportsScopedPickerCacheCleanup(TargetPlatform platform) => platform == TargetPlatform.android;

/// Conservative reference guard: terminal jobs retain their sources for retry.
/// In-flight acquisitions are additionally protected by sourceCacheLeaseProvider.
bool shouldPreserveSendingCaches({required bool hasSelection, required bool hasQueueJobs, required bool hasSendSessions}) =>
    hasSelection || hasQueueJobs || hasSendSessions;

final registeredReceiveCacheCleanupProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    await cleanRegisteredReceiveCaches();
  },
);
final generalTemporaryCacheCleanupProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    // Resolve the root token outside the background isolate closure.
    final token = ServicesBinding.rootIsolateToken!;
    await Isolate.run(() => _clear(token));
  },
);

/// Clears the cache.
/// It runs on a separate isolate to avoid blocking the UI.
class ClearCacheAction extends AsyncGlobalAction {
  @override
  Future<void> reduce() async {
    // Registered receive cleanup has ownership checks independent of send caches
    // and still runs while sending. Re-read sources after its awaited work.
    await ref.read(registeredReceiveCacheCleanupProvider)();
    try {
      await ref.notifier(workspaceCaptureStoreProvider).clean();
    } catch (_) {
      _logger.warning('Owned workspace export cleanup retained failures');
    }
    await ref
        .read(sourceCacheLeaseProvider)
        .cleanIfIdle(
          inUse: () {
            final server = ref.read(serverProvider);
            return shouldPreserveSendingCaches(
                  hasSelection: ref.read(selectedSendingFilesProvider).isNotEmpty,
                  hasQueueJobs: ref.read(sendQueueProvider).isNotEmpty,
                  hasSendSessions: ref.read(sendProvider).isNotEmpty,
                ) ||
                server?.session != null ||
                (server?.webDownloadState?.files.isNotEmpty ?? false);
          },
          cleanup: () async {
            // Keep this platform call on the host messenger and under the same
            // lease as source-reference checks; the worker isolate has no UI channel.
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) await clearImportedIosDrops();
            await ref.read(generalTemporaryCacheCleanupProvider)();
          },
        );
  }
}

Future<void> _clear(RootIsolateToken token) async {
  initLogger(Level.ALL);
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);

  // Only the plugins' own cache stores are eligible. The temporary root can
  // contain live gallery exports, and the iOS app group has external writers;
  // neither is an ownership registry and neither may be swept indiscriminately.
  // Wait for every plugin completion, including failure, before releasing the
  // host lease. Registered .ls cleanup remains separate and ownership checked.
  try {
    await (
      supportsScopedPickerCacheCleanup(defaultTargetPlatform) ? FilePicker.clearTemporaryFiles() : Future<bool?>.value(),
      PhotoManager.clearFileCache(),
    ).wait;
  } catch (e) {
    _logger.warning('Failed to clear plugin caches: $e');
  }
}
