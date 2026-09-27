import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/channel_health_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/channel_health_strings.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/send_route_strings.dart';
import 'package:localsend_app/widget/list_tile/device_list_tile.dart';
import 'package:localsend_app/widget/send_network_controls.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

const lan = HttpChannel(host: '192.168.1.9', port: 53317, https: false);
const tunnel = HttpChannel(host: '10.8.0.9', port: 53318, https: true);
final peer = Device.empty.copyWith(alias: 'Legna peer', fingerprint: 'peer', ip: lan.host, port: lan.port, channels: [lan, tunnel]);
const network = NetworkState(
  localIps: ['192.168.1.2', '10.8.0.2'],
  initialized: true,
  addresses: [
    LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.2', prefixLength: 24, wifi: true),
    LocalNetworkAddress(interfaceName: 'utun1', address: '10.8.0.2', prefixLength: 24),
  ],
);

class TestNetwork extends LocalIpService {
  TestNetwork(super.settings) : super(monitor: false);
  @override
  NetworkState init() => network;
}

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('entry point dialog and filter remain interactive on a narrow screen (${locale.name})', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => LocaleSettings.setLocale(locale));
      final settings = SettingsService(MockPersistenceService());
      late Ref ref;
      var sends = 0;
      var probes = 0;
      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            localIpProvider.overrideWithNotifier((_) => TestNetwork(settings)),
            nearbyChannelDevicesProvider.overrideWithBuilder((_) => {}),
            channelProbeProvider.overrideWithValue((device, channel, route) async {
              expect(device.fingerprint, peer.fingerprint);
              expect(channel, tunnel);
              probes++;
              return true;
            }),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (context, current) {
                    ref = current;
                    return ListView(
                      children: [
                        const SendNetworkFilter(),
                        DeviceListTile(device: peer, showChannelSelector: true, onTap: () => sends++),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('network-filter-tunnel')));
      await tester.pumpAndSettle();
      expect(ref.read(sendNetworkFilterProvider), 'tunnel');
      await tester.tap(find.byKey(const ValueKey('send-channel-peer')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(SendRouteStrings(locale).hint), findsOneWidget);
      expect(sends, 0, reason: 'selecting a channel must not bubble into send');
      final probe = find.byKey(ValueKey('probe-${httpChannelLabel(tunnel)}'));
      await tester.ensureVisible(probe);
      await tester.tap(probe);
      await tester.pumpAndSettle();
      expect(probes, 1);
      expect(sends, 0);
      expect(find.textContaining(ChannelHealthStrings(locale).reachable), findsOneWidget);

      await tester.ensureVisible(find.byKey(ValueKey('send-channel-option-${httpChannelLabel(tunnel)}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byKey(ValueKey('send-channel-option-${httpChannelLabel(tunnel)}')), matching: find.byIcon(Icons.radio_button_off)),
      );
      await tester.pumpAndSettle();
      expect(ref.read(sendRouteProvider)['peer'], tunnel);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('send-channel-peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('send-channel-auto')));
      await tester.pumpAndSettle();
      expect(ref.read(sendRouteProvider), isEmpty);
      expect(sends, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('send-local-route-peer')));
      await tester.tap(find.byKey(const ValueKey('send-local-route-peer')));
      await tester.pumpAndSettle();
      expect(find.text(SendRouteStrings(locale).bindingHint), findsNothing, reason: 'binding explanation stays behind the info action');
      await tester.tap(find.byKey(const ValueKey('send-local-route-info')));
      await tester.pumpAndSettle();
      expect(find.text(SendRouteStrings(locale).bindingHint), findsOneWidget);
      Navigator.of(tester.element(find.text(SendRouteStrings(locale).bindingHint))).pop();
      await tester.pumpAndSettle();
      final option = find.byKey(const ValueKey('send-local-route-option-utun1-10.8.0.2'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(ref.read(sendLocalRouteProvider)['peer'], const LocalSendRoute(interfaceName: 'utun1', localAddress: '10.8.0.2'));
      expect(ref.read(sendRouteProvider), isEmpty, reason: 'source and receiver choices are independent');
      expect(sends, 0, reason: 'local route selection does not send or bubble into the card');
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('send-local-route-peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('send-local-route-auto')));
      await tester.pumpAndSettle();
      expect(ref.read(sendLocalRouteProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Legna peer'));
      expect(sends, 1);
      ref.notifier(sendNetworkFilterProvider).select('interface:disconnected');
      await tester.pumpAndSettle();
      expect(find.text(SendRouteStrings(locale).missingNetwork), findsOneWidget);
      expect(ref.read(sendNetworkFilterProvider), 'interface:disconnected');
      expect(tester.takeException(), isNull);
    });
  }

  test('new UI choices do not mutate a previously captured route', () {
    final container = RefenaContainer();
    addTearDown(() => container.dispose(sendRouteProvider));
    container.notifier(sendRouteProvider).select(peer, lan);
    final captured = container.read(sendRouteProvider)['peer'];
    container.notifier(sendRouteProvider).select(peer, tunnel);
    expect(captured, lan);
    expect(container.read(sendRouteProvider)['peer'], tunnel);
    container.notifier(sendRouteProvider).select(peer, null);
    expect(captured, lan);
  });
}
