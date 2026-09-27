import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';

class _HostCatalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/workspaces/{workspaceId}/state': {
        'get': {
          'operationId': 'getWorkspaceState',
          'summary': 'Read workspace state',
          'x-legnasend-max-query-bytes': 24576,
          'parameters': [
            {
              'name': 'workspaceId',
              'in': 'path',
              'required': true,
              'schema': {'type': 'string', 'maxLength': 4096, 'x-legnasend-max-utf8-bytes': 4096},
            },
            {
              'name': 'generation',
              'in': 'query',
              'required': true,
              'schema': {'type': 'integer', 'minimum': 1, 'x-legnasend-max-utf8-bytes': 4096},
            },
            {
              'name': 'ids',
              'in': 'query',
              'required': false,
              'schema': {
                'type': 'string',
                'maxLength': 8192,
                'x-legnasend-max-utf8-bytes': 8192,
                'description': 'At most 64 canonical IDs, totaling at most 8192 bytes',
              },
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
    testWidgets('state ID field retains the documented 8192 bytes ${locale.languageTag}', (tester) async {
      final server = _HostServer()..failTransport = false;
      await mount(tester, server, locale);
      await tap(tester, 'api-operation-getWorkspaceState');
      await enter(tester, 'api-param-workspaceId', 'workspace');
      await enter(tester, 'api-param-generation', '1');
      await enter(tester, 'api-param-ids', 'a' * 8192);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('api-param-ids')));
      expect(field.maxLength, 8192);
      expect(field.controller!.text, hasLength(8192));
      expect(field.decoration!.helperText, contains('8192 bytes'));
      await tap(tester, 'api-execute');
      expect(server.calls, hasLength(1));
      expect(server.calls.single['operation'], 'getWorkspaceState');
      expect(server.calls.single['parameters']['ids'], hasLength(8192));
      expect(server.calls.single.containsKey('body'), false);
      // Programmatic/stale drafts are validated too, independently of text formatters.
      field.controller!.text = 'a' * 8193;
      await tester.pump();
      await tap(tester, 'api-execute');
      expect(server.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
