import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/refena.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../mocks.mocks.dart';

class _SensitiveState {
  final int value;
  _SensitiveState(this.value);
  @override
  String toString() => throw StateError('Release observer must not stringify state');
}

class _Plain extends Notifier<_SensitiveState> {
  @override
  _SensitiveState init() => _SensitiveState(0);
  void increment() => state = _SensitiveState(state.value + 1);
}

class _Redux extends ReduxNotifier<_SensitiveState> {
  @override
  _SensitiveState init() => _SensitiveState(0);
}

class _Increment extends ReduxAction<_Redux, _SensitiveState> {
  @override
  _SensitiveState reduce() => _SensitiveState(state.value + 1);
}

/// Changes only the input certificate fixture; uses the real SecurityService,
/// Redux dispatch and provider onChanged publication; certificate generation is
/// outside this callback-regression test.
class _ReplaceSecurity extends ReduxAction<SecurityService, StoredSecurityContext> {
  final StoredSecurityContext next;
  _ReplaceSecurity(this.next);
  @override
  StoredSecurityContext reduce() => next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('release observers preserve state, redux and view callbacks without logging or serializing', () async {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await logs.cancel();
      Logger.root.level = previousLevel;
    });
    final changes = <String>[];
    final plain = NotifierProvider<_Plain, _SensitiveState>((_) => _Plain(), onChanged: (_, next, _) => changes.add('plain:${next.value}'));
    final redux = ReduxProvider<_Redux, _SensitiveState>((_) => _Redux(), onChanged: (_, next, _) => changes.add('redux:${next.value}'));
    final view = ViewProvider((ref) => ref.watch(plain).value * 2, onChanged: (_, next, _) => changes.add('view:$next'));
    final observers = createAppRefenaObservers(debug: false);
    expect(observers, hasLength(1));
    expect(observers.single, isNot(isA<CustomRefenaObserver>()));
    expect(createAppRefenaObservers(debug: true).single, isA<CustomRefenaObserver>());
    final container = RefenaContainer(observers: observers);
    addTearDown(container.disposeContainer);
    expect(container.read(view), 0);
    container.notifier(plain).increment();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(view), 2);
    container.redux(redux).dispatch(_Increment());
    expect(changes, containsAll(['plain:1', 'view:2', 'redux:1']));
    expect(changes, hasLength(3));
    await Future<void>.value();
    expect(records, isEmpty);
  });

  test('production release configuration publishes network, device and certificate changes into real parent sync state', () async {
    const security = StoredSecurityContext(
      privateKey: 'initial-private',
      publicKey: 'initial-public',
      certificate: 'initial-cert',
      certificateHash: 'initial-hash',
    );
    const changedSecurity = StoredSecurityContext(
      privateKey: 'next-private',
      publicKey: 'next-public',
      certificate: 'next-cert',
      certificateHash: 'next-hash',
    );
    final info = DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'Initial model', androidSdkInt: null);
    final persistence = MockPersistenceService();
    when(persistence.getSecurityContext()).thenReturn(security);
    final sync = SyncState(
      rootIsolateToken: Object(),
      securityContext: security,
      deviceInfo: info,
      alias: 'Fixture',
      port: 53317,
      discoveryPort: 53317,
      networkWhitelist: null,
      networkBlacklist: null,
      protocol: ProtocolType.http,
      multicastGroup: '224.0.0.167',
      discoveryTimeout: 1000,
      serverRunning: false,
      download: false,
    );
    final container = RefenaContainer(
      observers: createAppRefenaObservers(debug: false),
      overrides: [
        persistenceProvider.overrideWithValue(persistence),
        deviceRawInfoProvider.overrideWithValue(info),
        parentIsolateProvider.overrideWithNotifier((_) => IsolateController(initialState: ParentIsolateState.initial(sync))),
      ],
    );
    addTearDown(container.disposeContainer);
    final settings = container.notifier(settingsProvider);
    container.read(deviceInfoProvider);
    container.read(securityProvider);
    SyncState current() => container.read(parentIsolateProvider).syncState;
    await settings.setNetworkWhitelist(['192.168.1.0/24']);
    expect(current().networkWhitelist, ['192.168.1.0/24']);
    await settings.setNetworkBlacklist(['10.0.0.0/8']);
    expect(current().networkBlacklist, ['10.0.0.0/8']);
    await settings.setMulticastGroup('224.0.0.168');
    expect(current().multicastGroup, '224.0.0.168');
    await settings.setDiscoveryTimeout(2500);
    expect(current().discoveryTimeout, 2500);
    await settings.setDeviceType(DeviceType.mobile);
    await Future<void>.delayed(Duration.zero);
    expect(current().deviceInfo.deviceType, DeviceType.mobile);
    await settings.setDeviceModel('Updated model');
    await Future<void>.delayed(Duration.zero);
    expect(current().deviceInfo.deviceModel, 'Updated model');
    container.redux(securityProvider).dispatch(_ReplaceSecurity(changedSecurity));
    expect(current().securityContext, same(changedSecurity));
    expect(current().networkWhitelist, ['192.168.1.0/24']);
    expect(current().deviceInfo.deviceModel, 'Updated model');
    expect(current().serverRunning, false);
    expect(current().download, false);
    verify(persistence.setNetworkWhitelist(['192.168.1.0/24'])).called(1);
    verify(persistence.setDeviceModel('Updated model')).called(1);
  });
}
