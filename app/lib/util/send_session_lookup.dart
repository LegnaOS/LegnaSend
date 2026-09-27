import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';

bool isActiveSendSession(SendSessionState session) =>
    session.status == SessionStatus.waiting || session.status == SessionStatus.sending || session.status == SessionStatus.connectionLost;

/// A changed IP is still the same device; a reused IP is not the same device.
/// Address-only favorites have no fingerprint yet and need an endpoint fallback.
bool isSameSendDevice(Device a, Device b) {
  if (a.fingerprint.isNotEmpty && b.fingerprint.isNotEmpty) {
    return a.fingerprint == b.fingerprint;
  }
  return a.ip != null && a.ip == b.ip && a.port == b.port && a.https == b.https;
}

/// Prefer the newest active session over any retained historical result.
SendSessionState? findDeviceSendSession(Iterable<SendSessionState> sessions, Device device, {bool activeOnly = false}) {
  SendSessionState? active;
  SendSessionState? latest;
  for (final session in sessions) {
    if (!isSameSendDevice(session.target, device)) continue;
    latest = session;
    if (isActiveSendSession(session)) active = session;
  }
  return active ?? (activeOnly ? null : latest);
}
