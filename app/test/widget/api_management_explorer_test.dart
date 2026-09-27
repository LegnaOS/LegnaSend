import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_management_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';
import '../unit/api/api_management_explorer_test.dart' show managementOperationFixture;

class _Catalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/managed-workspaces': {
        'get': {'operationId': 'listManagedWorkspaces', 'summary': 'Managed workspaces'},
      },
      '/workspaces/{workspaceId}/manage': {'post': managementOperationFixture()},
    },
    'components': {'schemas': {}},
  });
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

class _Server extends ApiTestServer {
  final calls = <Map<String, dynamic>>[];
  final response = Completer<String>();
  @override
  Future<String> integrationApiRequest({required int expectedGeneration, required String request}) {
    expect(expectedGeneration, epoch);
    calls.add(jsonDecode(request) as Map<String, dynamic>);
    return response.future;
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _Server server, AppLocale locale) async {
    const fontPath = String.fromEnvironment('API_MANAGEMENT_SCREENSHOT_FONT');
    if (fontPath.isNotEmpty) {
      await tester.runAsync(() async {
        final font = FontLoader('ApiManagementEvidenceFont')..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
        await font.load();
        const iconPath = String.fromEnvironment('API_MANAGEMENT_SCREENSHOT_ICONS');
        if (iconPath.isNotEmpty) {
          final icons = FontLoader('MaterialIcons')..addFont(File(iconPath).readAsBytes().then(ByteData.sublistView));
          await icons.load();
        }
      });
    }
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('api-management-capture'),
        child: RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(
            child: DefaultAssetBundle(
              bundle: _Catalog(),
              child: MaterialApp(
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: [locale.flutterLocale],
                locale: locale.flutterLocale,
                theme: ThemeData(
                  colorSchemeSeed: const Color(0xff54b865),
                  brightness: Brightness.dark,
                  fontFamily: fontPath.isEmpty ? null : 'ApiManagementEvidenceFont',
                ),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.35)),
                  child: child!,
                ),
                home: ApiExplorerPage(pickUploadSource: () async => throw StateError('Management must not pick files')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('api-operation-manageWorkspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-operation-manageWorkspace')));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(target, 180, scrollable: find.byType(Scrollable).first);
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> value(WidgetTester tester, String name, String value) async {
    await reveal(tester, 'api-param-$name');
    await tester.enterText(find.byKey(ValueKey('api-param-$name')), value);
  }

  Future<void> choose(WidgetTester tester, String name, String value) async {
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pumpAndSettle();
    await reveal(tester, 'api-param-$name');
    final control = find.byKey(ValueKey('api-param-$name'));
    final dropdown = tester.widget<DropdownButton<String>>(control);
    final item = dropdown.items!.singleWhere((item) => item.value == value);
    final label = (item.child as Text).data!;
    await tester.tap(control);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> prepare(WidgetTester tester, String action) async {
    await value(tester, 'workspaceId', 'managed-workspace');
    await value(tester, 'generation', '12');
    await choose(tester, 'action', action);
  }

  Future<void> execute(WidgetTester tester) async {
    await reveal(tester, 'api-execute');
    await tester.tap(find.byKey(const ValueKey('api-execute')));
    await tester.pumpAndSettle();
  }

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhHk]) {
    testWidgets(
      'management confirms explicit changes, cancels inertly and shows stale response ${locale.languageTag}',
      (tester) async {
        final server = _Server();
        await mount(tester, server, locale);
        await prepare(tester, 'update');
        expect(find.byKey(const ValueKey('api-upload-pick')), findsNothing);
        await execute(tester);
        expect(server.calls, isEmpty);
        expect(find.byKey(const ValueKey('api-management-confirmation')), findsNothing);
        expect(find.text(ApiManagementStrings(locale.languageTag).emptyUpdate), findsOneWidget);
        await value(tester, 'name', 'New 名称');
        await choose(tester, 'visible', 'false');
        expect(tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('api-param-allowUpload'))).value, '');
        await execute(tester);
        expect(find.byKey(const ValueKey('api-management-confirmation')), findsOneWidget);
        const capture = String.fromEnvironment('API_MANAGEMENT_SCREENSHOTS');
        if (capture.isNotEmpty) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('api-management-capture')));
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await Directory(capture).create(recursive: true);
              await File('$capture/api-management-${locale.languageTag}-${defaultTargetPlatform.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        expect(server.calls, isEmpty);
        expect(find.text('generation: 12'), findsOneWidget);
        expect(find.textContaining('New 名称'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('api-management-decline')));
        await tester.pumpAndSettle();
        expect(server.calls, isEmpty);
        await execute(tester);
        await tester.tap(find.byKey(const ValueKey('api-management-confirm')));
        await tester.pump();
        expect(server.calls.single['operation'], 'manageWorkspace');
        expect(server.calls.single['parameters'], {
          'workspaceId': 'managed-workspace',
          'generation': '12',
          'action': 'update',
          'name': 'New 名称',
          'visible': 'false',
        });
        expect(server.calls.single.containsKey('uploadPath'), false);
        server.response.complete(
          jsonEncode({
            'status': 409,
            'elapsedMs': 2,
            'bytes': 24,
            'headers': {},
            'body': '{"error":"stale_generation"}',
            'binary': false,
            'truncated': false,
          }),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('HTTP 409'), 180, scrollable: find.byType(Scrollable).first);
        expect(find.text('HTTP 409'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(server.calls.length, 1);
        expect(find.byKey(const ValueKey('api-management-result-guidance')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
  testWidgets('destroy clears update drafts, describes metadata only, and preserves uncertain response', (tester) async {
    final server = _Server();
    await mount(tester, server, AppLocale.en);
    await prepare(tester, 'update');
    await value(tester, 'name', 'discard draft');
    await choose(tester, 'allowUpload', 'true');
    await choose(tester, 'action', 'destroy');
    expect(find.byKey(const ValueKey('api-param-name')), findsNothing);
    expect(find.byKey(const ValueKey('api-param-allowUpload')), findsNothing);
    await execute(tester);
    expect(find.text(const ApiManagementStrings('en').destroy), findsOneWidget);
    expect(find.byKey(const ValueKey('api-upload-confirmation')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('api-management-confirm')));
    await tester.pump();
    expect(server.calls.single['parameters'], {'workspaceId': 'managed-workspace', 'generation': '12', 'action': 'destroy'});
    server.response.complete(
      jsonEncode({
        'status': 504,
        'elapsedMs': 2,
        'bytes': 99,
        'headers': {},
        'body': '{"error":"outcome_unknown","state":"config_saved_sync_pending"}',
        'binary': false,
        'truncated': false,
      }),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('HTTP 504'), 180, scrollable: find.byType(Scrollable).first);
    expect(find.text('HTTP 504'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('config_saved_sync_pending'), 180, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('outcome_unknown'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(server.calls.length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unconfirmed network outcome never promises a rollback or retries', (tester) async {
    final server = _Server();
    await mount(tester, server, AppLocale.en);
    await prepare(tester, 'disable');
    await execute(tester);
    await tester.tap(find.byKey(const ValueKey('api-management-confirm')));
    await tester.pump();
    server.response.completeError(StateError('request lost'));
    await tester.pumpAndSettle();
    expect(find.text(const ApiManagementStrings('en').unknown), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(server.calls.length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'password stays obscured, body-only, clears on action switch and after response',
    (tester) async {
      final server = _Server();
      await mount(tester, server, AppLocale.en);
      await prepare(tester, 'password');
      await reveal(tester, 'api-body-password');
      final password = find.byKey(const ValueKey('api-body-password'));
      expect(tester.widget<TextField>(password).obscureText, true);
      await tester.enterText(password, 'Private-9381');
      await choose(tester, 'action', 'configure');
      await choose(tester, 'action', 'password');
      await reveal(tester, 'api-body-password');
      expect(tester.widget<TextField>(password).controller!.text, isEmpty);
      await tester.enterText(password, 'Private-9381');
      await execute(tester);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('Private-9381')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('api-management-confirm')));
      await tester.pump();
      expect(server.calls.single['body'], {'password': 'Private-9381'});
      expect(server.calls.single['parameters'], {'workspaceId': 'managed-workspace', 'generation': '12', 'action': 'password'});
      server.response.complete(
        jsonEncode({'status': 200, 'elapsedMs': 1, 'bytes': 2, 'headers': {}, 'body': '{}', 'binary': false, 'truncated': false}),
      );
      await tester.pumpAndSettle();
      await reveal(tester, 'api-body-password');
      expect(tester.widget<TextField>(password).controller!.text, isEmpty);
      expect(server.calls.length, 1);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );
}
