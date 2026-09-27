import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/util/send_session_lookup.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:test/test.dart';

Device device(String fingerprint, String? ip) => Device.empty.copyWith(fingerprint: fingerprint, ip: ip, port: 53317, https: true);
SendSessionState session(String id, Device target, SessionStatus status) => SendSessionState(
  sessionId: id,
  remoteSessionId: null,
  background: true,
  status: status,
  target: target,
  files: {},
  hashedFileCount: 0,
  startTime: null,
  endTime: null,
  sendingTasks: [],
  errorMessage: null,
);

void main() {
  test('IP changes preserve identity; reused and null IPs do not merge devices', () {
    expect(isSameSendDevice(device('a', '10.0.0.1'), device('a', '10.1.0.1')), isTrue);
    expect(isSameSendDevice(device('a', '10.0.0.1'), device('b', '10.0.0.1')), isFalse);
    expect(isSameSendDevice(device('a', null), device('b', null)), isFalse);
    expect(isSameSendDevice(device('', null), device('', null)), isFalse);
  });
  test('address-only devices fall back to the full endpoint', () {
    expect(isSameSendDevice(device('', '10.0.0.1'), device('a', '10.0.0.1')), isTrue);
    expect(isSameSendDevice(device('', '10.0.0.1'), device('a', '10.0.0.1').copyWith(port: 1234)), isFalse);
  });
  test('retained errors never block a new send', () {
    final target = device('a', '10.0.0.1');
    for (final status in SessionStatus.values.where((s) => s != SessionStatus.waiting && s != SessionStatus.sending && s != SessionStatus.connectionLost)) {
      final previous = session('old', target, status);
      expect(findDeviceSendSession([previous], target, activeOnly: true), isNull);
    }
  });
  test('active session wins over retained history, newest result otherwise', () {
    final target = device('a', '10.0.0.1');
    final active = session('new', target, SessionStatus.sending);
    final old = session('old', target, SessionStatus.finishedWithErrors);
    expect(findDeviceSendSession([active, old], target), same(active));
    expect(findDeviceSendSession([old, session('last', target, SessionStatus.finished)], target)?.sessionId, 'last');
  });
}
