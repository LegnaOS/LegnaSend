import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:refena_inspector_client/refena_inspector_client.dart';

final _logger = Logger('Refena');

/// Selects the same callback-capable container configuration in every build mode.
List<RefenaObserver> createAppRefenaObservers({bool debug = kDebugMode}) => [
  if (debug) CustomRefenaObserver() else _ReleaseStateObserver(),
];

/// Compatibility workaround for pinned Refena 3.5.0: BaseNotifier._setState and
/// _setStateAsRebuild invoke provider onChanged only when an observer exists.
/// Those callbacks publish settings, certificates and device metadata to child
/// isolates; omitting an observer silently breaks release/profile networking.
///
/// This observer does not log, trace, inspect or stringify any event/state. Keep
/// it until Refena is upgraded to a version whose observer-free change AND view
/// rebuild paths invoke onChanged, and the release synchronization tests pass
/// with the workaround removed. Debug tracing remains independently opt-in.
class _ReleaseStateObserver extends RefenaObserver {
  @override
  void handleEvent(RefenaEvent event) {}
}

class CustomRefenaObserver extends RefenaMultiObserver {
  CustomRefenaObserver()
    : super(
        observers: [
          RefenaDebugObserver(
            onLine: (line) => _logger.info(line),
            exclude: _exclude,
          ),
          RefenaTracingObserver(
            limit: 100,
            exclude: _exclude,
          ),
          RefenaInspectorObserver(),
        ],
      );
}

bool _exclude(RefenaEvent event) {
  return switch (event) {
    ChangeEvent() => event.notifier is DiscoveryLogger || event.notifier is LocalIpService || event.notifier is FileTransferNotifier,
    ActionDispatchedEvent() => event.action.runtimeType.toString() == '_FetchLocalIpAction',
    ActionFinishedEvent() => event.action.runtimeType.toString() == '_FetchLocalIpAction',
    _ => false,
  };
}
