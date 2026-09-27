import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/widget/share_address_list.dart';

void main() {
  const v4 = LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.2');
  const v6 = LocalNetworkAddress(interfaceName: 'en0', address: '240e::12');
  const vpn = LocalNetworkAddress(interfaceName: 'utun4', address: '198.18.0.1');
  testWidgets('IPv4 precedes VPN and collapsed IPv6; expansion retains all routes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShareAddressList(
            addresses: const [
              v6,
              vpn,
              v4,
              v4,
              LocalNetworkAddress(interfaceName: 'en0', address: 'fe80::1'),
            ],
            moreLabel: 'More addresses',
            itemBuilder: (a) => Text(a.address),
          ),
        ),
      ),
    );
    expect(find.text(v4.address), findsOneWidget);
    expect(find.text(vpn.address), findsNothing);
    expect(find.text(v6.address), findsNothing);
    await tester.tap(find.text('More addresses (2)'));
    await tester.pumpAndSettle();
    expect(find.text(vpn.address), findsOneWidget);
    expect(find.text(v6.address), findsOneWidget);
    expect(find.text('fe80::1'), findsNothing);
  });
  testWidgets('IPv6-only networks retain a usable visible address', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShareAddressList(addresses: const [v6], moreLabel: 'More', itemBuilder: (a) => Text(a.address)),
      ),
    );
    expect(find.text(v6.address), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
  });
}
