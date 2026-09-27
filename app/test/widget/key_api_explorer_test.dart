import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_key_strings.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';

class _KeyCatalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/keys/create': {
        'post': {'operationId': 'createKey', 'summary': 'Create a key', 'parameters': [], 'responses': {}},
      },
      '/keys/{keyId}/manage': {
        'post': {
          'operationId': 'manageKey',
          'summary': 'Manage a key',
          'parameters': [
            {
              'name': 'keyId',
              'in': 'path',
              'required': true,
              'schema': {'type': 'string', 'format': 'uuid'},
            },
          ],
          'responses': {},
        },
      },
    },
    'components': {'schemas': {}},
  });
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

/// The actual explorer calls this boundary. Wire authorization/version checks
/// remain covered separately by native/core HTTP tests, not this widget fixture.
class _KeyServer extends ApiTestServer {
  bool failTransport = true;
  int responseStatus = 200;
  final calls = <Map<String, dynamic>>[];
  final generations = <int>[];
  @override
  Future<String> integrationApiRequest({required int expectedGeneration, required String request}) async {
    calls.add(jsonDecode(request) as Map<String, dynamic>);
    generations.add(expectedGeneration);
    if (failTransport) throw StateError('/private/user/secret-path: transport interrupted');
    final body = jsonEncode({
      'receipt': {'keyId': '11111111-1111-4111-8111-111111111111'},
      'applied': true,
      'secretAvailable': true,
      'secret': 'ls1.11111111-1111-4111-8111-111111111111.${'z' * 43}',
    });
    return jsonEncode({'status': 201, 'body': body, 'headers': {}, 'elapsedMs': 1, 'bytes': body.length});
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _KeyServer server, AppLocale locale) async {
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
            bundle: _KeyCatalog(),
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
    testWidgets('key mutations confirm and one-time secret is masked then removed ${locale.languageTag}', (tester) async {
      final server = _KeyServer();
      await mount(tester, server, locale);
      await tap(tester, 'api-operation-createKey');
      await enter(tester, 'api-body-version', 'a' * 64);
      await enter(tester, 'api-body-name', 'Reader');
      await enter(tester, 'api-body-scopes', 'service.read, files.read');
      await enter(tester, 'api-body-workspaces', '*');
      await tap(tester, 'api-execute');
      expect(find.byKey(const ValueKey('api-key-confirmation')), findsOneWidget);
      expect(server.calls, isEmpty);
      await tap(tester, 'api-key-decline');
      expect(server.calls, isEmpty);
      await tap(tester, 'api-execute');
      await tap(tester, 'api-key-confirm');
      expect(server.calls, hasLength(1));
      expect(server.calls.single['body']['expiresAt'], isNull);
      expect(server.calls.single['body']['grant'], {
        'scopes': ['service.read', 'files.read'],
        'workspaces': ['*'],
      });
      await reveal(tester, 'api-console-error');
      expect(tester.widget<Text>(find.byKey(const ValueKey('api-console-error'))).data, ApiKeyStrings(locale.languageTag).unknown);
      server.failTransport = false;
      await tap(tester, 'api-execute');
      await tap(tester, 'api-key-confirm');
      expect(find.byKey(const ValueKey('api-key-secret')), findsOneWidget);
      final secretField = tester.widget<TextField>(find.byKey(const ValueKey('api-key-secret-value')));
      final controller = secretField.controller!;
      expect(secretField.obscureText, isTrue);
      expect(controller.text, startsWith('ls1.'));
      await tap(tester, 'api-key-secret-close');
      expect(find.byKey(const ValueKey('api-key-secret')), findsNothing);
      expect(find.textContaining('ls1.'), findsNothing);
      expect(server.calls.last, server.calls.first);
      await tap(tester, 'api-operation-manageKey');
      await enter(tester, 'api-param-keyId', '11111111-1111-4111-8111-111111111111');
      await enter(tester, 'api-body-version', 'a' * 64);
      await enter(tester, 'api-body-action', 'pause');
      await tap(tester, 'api-execute');
      expect(find.byKey(const ValueKey('api-key-confirmation')), findsOneWidget);
      await tap(tester, 'api-key-decline');
      expect(server.calls, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }
}
