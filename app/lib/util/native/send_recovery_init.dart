import 'dart:io';

import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/send_recovery_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/provider/workspace_capture_provider.dart';
import 'package:localsend_app/util/native/source_end_init.dart';
import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('SendRecoveryInitialization');

// Log the operation and error class, not paths or persisted cleanup credentials.
void _logFailure(String phase, Object error) {
  final code = error is FileSystemException ? error.osError?.errorCode : null;
  final nativeCode = RegExp(r'source_end_journal_unavailable\(kind=([A-Za-z]+), errno=(none|-?[0-9]+)\)').firstMatch(error.toString());
  final detail = nativeCode == null ? (code == null ? '' : ', os=$code') : ', kind=${nativeCode[1]}, os=${nativeCode[2]}';
  _logger.warning('$phase failed (${error.runtimeType}$detail)');
}

/// Restore metadata only; external files and peers are checked on user action.
/// Keep this journal outside temporary caches and downloads, including portable mode.
Future<void> initializeSendRecovery(
  RefenaContainer container, {
  required bool portable,
  Future<String> Function()? supportDirectory,
  String Function()? portableSettingsPath,
  Future<void> Function(RefenaContainer, String)? sourceEndInitializer,
}) async {
  try {
    final root = portable
        ? File((portableSettingsPath ?? () => SharedPreferencesPortable().getPath())()).parent.path
        : await (supportDirectory ?? () async => (await getApplicationSupportDirectory()).path)();
    await container.set(sendRecoveryStoreProvider.overrideWithValue(SendRecoveryStore(Directory(p.join(root, '.legnasend-send-recovery')))));
    await container.notifier(sendQueueProvider).initializeRecovery();
    // A control-journal failure does not destroy ordinary send recovery.
    try {
      await (sourceEndInitializer ?? initializeSourceEndStore)(container, root);
    } catch (error) {
      _logFailure('Cleanup notification storage initialization', error);
      // The send manifest may already be healthy. Do not mislabel a separate
      // control journal as failed sends, or overwrite a real recovery failure.
      if (container.read(sendRecoveryIssueProvider) == null) {
        container.notifier(sendRecoveryIssueProvider).report('cleanupStorage');
      }
    }
    await container.notifier(sourceEndProvider).initialize();
    await container.notifier(workspaceCaptureStoreProvider).initialize();
  } catch (error) {
    _logFailure('Send recovery initialization', error);
    container.notifier(sendRecoveryIssueProvider).report('storage');
  }
}
