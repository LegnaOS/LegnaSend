import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:localsend_isolates/rust/api/receive_cache.dart' as native;
import 'package:refena_flutter/refena_flutter.dart' hide ChangeNotifier;

// Compatibility encoding: -2 means exactly one hour, not negative days.
const receiveCacheRetentionOneHour = -2;
const receiveCacheRetentionChoices = [receiveCacheRetentionOneHour, 0, -1, 1, 7, 30];
bool validReceiveCacheRetentionDays(int days) => days == receiveCacheRetentionOneHour || days == -1 || (days >= 0 && days <= 3650);
int parseReceiveCacheRetentionPolicy(String raw) {
  final value = jsonDecode(raw);
  if (value is! Map || value.length != 2) throw const FormatException('Invalid retention policy');
  return switch ((value['mode'], value['days'])) {
    ('immediate', null) => 0,
    ('hour', null) => receiveCacheRetentionOneHour,
    ('manual', null) => -1,
    ('days', final int days) when days >= 1 && days <= 3650 => days,
    _ => throw const FormatException('Invalid retention policy'),
  };
}

final receiveCacheRetentionProvider = NotifierProvider<ReceiveCacheRetentionOwner, ReceiveCacheRetentionController>(
  (ref) => ReceiveCacheRetentionOwner(),
);

class ReceiveCacheRetentionOwner extends Notifier<ReceiveCacheRetentionController> {
  @override
  ReceiveCacheRetentionController init() => ReceiveCacheRetentionController(
    readSaved: () => ref.read(settingsProvider).receiveCacheRetentionDays,
    savedInvalid: () => ref.read(persistenceProvider).hasInvalidReceiveCacheRetentionDays(),
    save: (days) => ref.notifier(settingsProvider).setReceiveCacheRetentionDays(days),
    configure: (days) async => parseReceiveCacheRetentionPolicy(
      await native.configureReceiveCacheRetentionPolicy(
        mode: days == receiveCacheRetentionOneHour
            ? 'hour'
            : days == -1
            ? 'manual'
            : days == 0
            ? 'immediate'
            : 'days',
        days: days > 0 ? days : null,
      ),
    ),
    readActual: () async => parseReceiveCacheRetentionPolicy(await native.getReceiveCacheRetentionPolicy()),
  );
  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }
}

/// Saved preference and actual process policy are deliberately distinct.
/// No cleanup is triggered by changing this preference.
class ReceiveCacheRetentionController extends ChangeNotifier {
  final int Function() readSaved;
  final bool Function()? savedInvalid;
  final Future<void> Function(int) save;
  final Future<int> Function(int) configure;
  final Future<int> Function() readActual;
  final void Function(bool) allowAutomatic;
  int days = receiveCacheRetentionOneHour;
  bool ready = false, busy = false;
  bool automaticCleanupAllowed = false;
  String? error;
  bool _disposed = false;
  ReceiveCacheRetentionController({
    required this.readSaved,
    this.savedInvalid,
    required this.save,
    required this.configure,
    required this.readActual,
    this.allowAutomatic = setAutomaticReceiveCacheCleanupAllowed,
  });
  Map<String, Object?> snapshot() => {
    'effectiveDays': ready ? days : null,
    'automaticCleanupPaused': !automaticCleanupAllowed,
    'busy': busy,
    'error': error,
  };

  void _setAutomatic(bool allowed) {
    automaticCleanupAllowed = allowed;
    allowAutomatic(allowed);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> initialize() => _change(readSaved(), persist: false);
  Future<bool> change(int next) => _change(next, persist: true);
  Future<bool> _change(int next, {required bool persist}) async {
    if (_disposed || busy) return false;
    if (!validReceiveCacheRetentionDays(next)) throw ArgumentError.value(next);
    final previousSaved = readSaved();
    busy = true;
    error = null;
    _setAutomatic(false);
    _notify();
    var phase = persist ? 'save' : 'apply';
    try {
      if (persist) await save(next);
      phase = 'apply';
      final actual = await configure(next);
      if (actual != next) throw const FormatException('Retention acknowledgement mismatch');
      days = actual;
      ready = true;
      if (!persist && (savedInvalid?.call() ?? false)) {
        error = 'invalid';
        return false;
      }
      return true;
    } catch (_) {
      error = phase;
      if (persist) {
        try {
          await save(previousSaved);
        } catch (_) {
          error = 'restore';
        }
      }
      try {
        days = await readActual();
        ready = validReceiveCacheRetentionDays(days);
      } catch (_) {
        ready = false;
      }
      return false;
    } finally {
      busy = false;
      // Unknown runtime or uncertain persistence keeps automatic deletion paused.
      _setAutomatic(!_disposed && ready && days == readSaved() && error != 'restore' && (persist || error == null));
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _setAutomatic(false);
    super.dispose();
  }
}
