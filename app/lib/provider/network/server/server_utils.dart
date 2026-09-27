import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Having this class allows us to have one parameter to access all relevant server methods.
class ServerUtils {
  /// The ref to the provider.
  Ref Function() refFunc;
  Ref get ref => refFunc();

  /// The current server state.
  /// This should be used within route controllers because it is guaranteed to be online and therefore non-null.
  ServerState Function() getState;

  /// The current server state or null.
  /// This should be used outside of routes because the server may be offline.
  ServerState? Function() getStateOrNull;

  /// Lifetime of the actual listening socket, independent of web-share revisions.
  /// Capture before an await to avoid applying old work to a restarted listener.
  final int Function() getListenerGeneration;

  /// Updates the server state.
  void Function(ServerState? Function(ServerState? oldState) builder) setState;

  ServerUtils({
    required this.refFunc,
    required this.getState,
    required this.getStateOrNull,
    required this.setState,
    int Function()? getListenerGeneration,
  }) : getListenerGeneration = getListenerGeneration ?? (() => 0);
}
