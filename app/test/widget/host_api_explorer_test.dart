import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_transfer_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';

class _HostCatalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/cache': {
        'get': {'operationId': 'inspectCache', 'summary': 'Inspect caches', 'parameters': [], 'responses': {}},
      },
      '/cache/cleanup': {
        'post': {'operationId': 'cleanupCache', 'summary': 'Clean caches', 'parameters': [], 'responses': {}},
      },
      '/settings': {
        'get': {'operationId': 'readSettings', 'summary': 'Read settings', 'parameters': [], 'responses': {}},
      },
      '/settings/update': {
        'post': {'operationId': 'updateSettings', 'summary': 'Update settings', 'parameters': [], 'responses': {}},
      },
    },
    'components': {'schemas': {}},
  });
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

/// The actual explorer calls this boundary. Wire authorization/version checks
/// remain covered separately by native/core HTTP tests, not this widget fixture.
class _HostServer extends ApiTestServer {
  bool failTransport = true;
  int responseStatus = 200;
  final calls = <Map<String, dynamic>>[];
  final generations = <int>[];
  @override
  Future<String> integrationApiRequest({required int expectedGeneration, required String request}) async {
    calls.add(jsonDecode(request) as Map<String, dynamic>);
    generations.add(expectedGeneration);
    if (failTransport) throw StateError('/private/user/secret-path: transport interrupted');
    final body = responseStatus == 409 ? '{"error":{"code":"settings_changed"}}' : '{"ok":true}';
    return jsonEncode({'status': responseStatus, 'body': body, 'headers': {}, 'elapsedMs': 1, 'bytes': body.length});
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _HostServer server, AppLocale locale) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: TranslationProvider(
          child: DefaultAssetBundle(
            bundle: _HostCatalog(),
            child: MaterialApp(
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: [locale.flutterLocale],
              locale: locale.flutterLocale,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              ),
              home: const ApiExplorerPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    if (key.startsWith('api-operation-')) {
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      await tester.pumpAndSettle();
    }
    final target = find.byKey(ValueKey(key));
    if (target.evaluate().isEmpty) await tester.scrollUntilVisible(target, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await reveal(tester, key);
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String key, String value) async {
    await reveal(tester, key);
    await tester.enterText(find.byKey(ValueKey(key)), value);
    await tester.pumpAndSettle();
  }

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    for (final operation in ['cleanupCache', 'updateSettings']) {
      testWidgets('$operation requires page confirmation, cancel sends nothing, failure is visible ${locale.languageTag}', (tester) async {
        final server = _HostServer();
        await mount(tester, server, locale);
        await tap(tester, 'api-operation-$operation');
        final copy = ApiTransferStrings(locale.languageTag);
        expect(find.text(copy.hostOperation), findsOneWidget);
        if (operation == 'updateSettings') {
          await enter(tester, 'api-body-version', 'a' * 64);
          await enter(tester, 'api-body-field', 'enableAnimations');
          await enter(tester, 'api-body-value', 'false');
        }
        await tap(tester, 'api-execute');
        expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsOneWidget);
        expect(server.calls, isEmpty);
        await tap(tester, 'api-transfer-decline');
        expect(server.calls, isEmpty);
        await tap(tester, 'api-execute');
        await tap(tester, 'api-transfer-confirm');
        expect(server.calls, hasLength(1));
        expect(server.calls.single['operation'], operation);
        expect(server.generations, [1]);
        expect(server.calls.single['parameters'], isEmpty);
        if (operation == 'updateSettings') {
          expect(server.calls.single['body'], {'version': 'a' * 64, 'field': 'enableAnimations', 'value': false});
        } else {
          expect(server.calls.single.containsKey('body'), isFalse);
        }
        await reveal(tester, 'api-console-error');
        final error = tester.widget<Text>(find.byKey(const ValueKey('api-console-error'))).data!;
        expect(error, copy.hostUnknown);
        expect(error, isNot(contains('private')));
        await tester.pump(const Duration(seconds: 1));
        expect(server.calls, hasLength(1), reason: 'A mutation is never retried automatically');
        server.failTransport = false;
        await tap(tester, 'api-execute');
        expect(server.calls, hasLength(1), reason: 'Every retry still requires explicit confirmation');
        await tap(tester, 'api-transfer-confirm');
        expect(server.calls, hasLength(2));
        expect(server.calls.last, server.calls.first);
        expect(find.byKey(const ValueKey('api-console-error')), findsNothing);
        expect(find.text('HTTP 200'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('invalid settings version/boolean never reaches confirmation; HTTP conflict stays visible', (tester) async {
    final server = _HostServer()..failTransport = false;
    await mount(tester, server, AppLocale.en);
    await tap(tester, 'api-operation-updateSettings');
    await enter(tester, 'api-body-version', 'not-a-version');
    await enter(tester, 'api-body-field', 'enableAnimations');
    await enter(tester, 'api-body-value', 'false');
    await tap(tester, 'api-execute');
    expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsNothing);
    expect(server.calls, isEmpty);
    await enter(tester, 'api-body-version', 'a' * 64);
    await enter(tester, 'api-body-value', 'maybe');
    await tap(tester, 'api-execute');
    expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsNothing);
    expect(server.calls, isEmpty);
    await enter(tester, 'api-body-field', 'locale');
    await enter(tester, 'api-body-value', 'invalid locale');
    await tap(tester, 'api-execute');
    expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsNothing);
    expect(server.calls, isEmpty);
    await enter(tester, 'api-body-field', 'enableAnimations');
    await enter(tester, 'api-body-value', 'false');
    server.responseStatus = 409;
    await tap(tester, 'api-execute');
    await tap(tester, 'api-transfer-confirm');
    expect(server.calls, hasLength(1));
    expect(find.text('HTTP 409'), findsOneWidget);
    expect(find.textContaining('settings_changed'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
