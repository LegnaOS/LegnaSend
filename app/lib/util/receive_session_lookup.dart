import 'package:localsend_app/model/state/server/receive_session_state.dart';

/// Never let an unrelated receive session override the task being displayed.
ReceiveSessionState? receiveSessionForId(ReceiveSessionState? session, String sessionId) => session?.sessionId == sessionId ? session : null;
