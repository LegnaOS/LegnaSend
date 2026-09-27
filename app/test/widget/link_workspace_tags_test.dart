import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/transfer_activity_provider.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_app/widget/transfer_activity_shell.dart';
import 'package:refena_flutter/refena_flutter.dart';
import '../fixtures/transfer_fixtures.dart';
import '../mocks.mocks.dart';

const network = NetworkState(
  localIps: ['192.168.1.4', '192.168.9.4', '198.18.0.1'],
  initialized: true,
  proxyEnabled: true,
  proxyKnown: true,
  tunnelInterfaces: ['utun4'],
  addresses: [
    LocalNetworkAddress(interfaceName: 'en0', address: '192.168.1.4', prefixLength: 24, wifi: true),
    LocalNetworkAddress(interfaceName: 'en16', address: '192.168.9.4', prefixLength: 24),
    LocalNetworkAddress(interfaceName: 'utun4', address: '198.18.0.1', prefixLength: 30),
  ],
);

class WorkspaceServer extends ServerService {
  int appends = 0;
  bool? requestedPermission;
  int? requestedGeneration;
  @override
  int get generation => 9;
  @override
  ServerState? init() => ServerState(
    alias: 'LegnaSend',
    port: 53318,
    https: false,
    session: incoming('parallel'),
    web: const WebShareDownload(
      pin: null,
      duplex: true,
      allowUpload: true,
      state: WebDownloadState(files: {}, sessions: {}, autoAccept: false),
    ),
  );
  @override
  Future<bool> updateWebWorkspace({required int expectedGeneration, List<CrossFile> files = const [], bool? allowUpload}) async {
    requestedGeneration = expectedGeneration;
    appends += files.length;
    requestedPermission = allowUpload;
    return true;
  }
}

class TagNetwork extends LocalIpService {
  TagNetwork(super.settings) : super(monitor: false);
  @override
  NetworkState init() => network;
}

void main() {
  for (final append in [false, true]) {
    for (final size in [const Size(390, 844), const Size(1040, 900)]) {
      testWidgets(
        'filled tags and both entry points reuse the workspace ${size.width}, append=$append',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await LocaleSettings.setLocale(AppLocale.en);
          final capture = const bool.fromEnvironment('CAPTURE_LINK_UI');
          if (capture) {
            await tester.runAsync(() async {
              await (FontLoader('TagTest')..addFont(rootBundle.load('packages/yaru/assets/fonts/Ubuntu-R.ttf'))).load();
              await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
            });
          }
          final server = WorkspaceServer(), settings = SettingsService(MockPersistenceService());
          final key = GlobalKey<NavigatorState>(), paint = GlobalKey();
          final theme = getTheme(ColorMode.localsend, Colors.green, Brightness.light, null);
          await tester.pumpWidget(
            RepaintBoundary(
              key: paint,
              child: RefenaScope(
                overrides: [
                  serverProvider.overrideWithNotifier((_) => server),
                  settingsProvider.overrideWithNotifier((_) => settings),
                  localIpProvider.overrideWithNotifier((_) => TagNetwork(settings)),
                  networkEnvironmentProvider.overrideWithBuilder((_) => network),
                  transferActivityProvider.overrideWithBuilder((_) => []),
                ],
                child: TranslationProvider(
                  child: MaterialApp(
                    navigatorKey: key,
                    theme: theme.copyWith(textTheme: capture ? theme.textTheme.apply(fontFamily: 'TagTest') : null),
                    debugShowCheckedModeBanner: false,
                    builder: (_, child) => TransferActivityShell(navigatorKey: key, child: child!),
                    home: WebSharePage(files: append ? [queuedFile('added', 10)] : null),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(server.appends, append ? 1 : 0);
          if (append) expect(server.requestedGeneration, 9);
          expect(server.generation, 9);
          expect(server.state!.session!.sessionId, 'parallel');
          expect(find.text(t.transferNavigation.restartTitle), findsNothing);
          expect(find.byType(OutlinedButton), findsNothing);
          for (final label in ['Wi-Fi', 'en0', 'en16', 'utun4', '192.168.9.0/24', 'http://192.168.9.4:53318/share']) {
            expect(find.text(label), findsOneWidget);
          }
          expect(find.byType(StatusTag), findsWidgets);
          if (capture) {
            await tester.runAsync(() async {
              final image = await (paint.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await File('/tmp/legnasend-link-tags-${size.width.toInt()}.png').writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          final allow = find.widgetWithText(SwitchListTile, t.linkWorkspace.allowUpload);
          await tester.ensureVisible(allow);
          await tester.tap(allow);
          await tester.pumpAndSettle();
          expect(server.requestedPermission, false);
          expect(server.generation, 9);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
      );
    }
  }
}
