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
    final reading = calls.last['operation'] == 'readSettings';
    final status = reading ? 200 : responseStatus;
    final body = jsonEncode(
      status == 503
          ? {
              'error': {'code': 'host_operation_failed'},
            }
          : {
              'version': 'b' * 64,
              'settings': {'receiveCacheRetentionDays': 7},
              'pendingRestart': <String>[],
              'receiveCacheRetention': {'effectiveDays': -1, 'automaticCleanupPaused': true, 'busy': false, 'error': 'apply'},
            },
    );
    return jsonEncode({'status': status, 'body': body, 'headers': {}, 'elapsedMs': 1, 'bytes': body.length});
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _HostServer server, AppLocale locale) async {
    await tester.binding.setSurfaceSize(const Size(360, 1000));
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
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
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
    testWidgets('retention typed integer requires confirmation and exposes failed actual state ${locale.languageTag}', (tester) async {
      final server = _HostServer()..failTransport = false;
      await mount(tester, server, locale);
      await tap(tester, 'api-operation-updateSettings');
      await enter(tester, 'api-body-version', 'a' * 64);
      await enter(tester, 'api-body-field', 'receiveCacheRetentionDays');
      for (final invalid in ['true', '"7"', '7.5', '3651', '-2']) {
        await enter(tester, 'api-body-value', invalid);
        await tap(tester, 'api-execute');
        expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsNothing);
        expect(server.calls, isEmpty);
      }
      await enter(tester, 'api-body-value', '-1');
      await tap(tester, 'api-execute');
      expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsOneWidget);
      expect(server.calls, isEmpty);
      await tap(tester, 'api-transfer-decline');
      expect(server.calls, isEmpty);
      server.responseStatus = 503;
      await tap(tester, 'api-execute');
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls, hasLength(1));
      expect(server.calls.single['body'], {'version': 'a' * 64, 'field': 'receiveCacheRetentionDays', 'value': -1});
      expect(server.calls.single['body']['value'], isA<int>());
      expect(find.text('HTTP 503'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('host_operation_failed'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('host_operation_failed'), findsWidgets);
      await tester.pump(const Duration(seconds: 1));
      expect(server.calls, hasLength(1), reason: 'Failed settings writes are never automatically retried');
      await tap(tester, 'api-operation-readSettings');
      await tap(tester, 'api-execute');
      expect(server.calls, hasLength(2));
      expect(server.calls.last['operation'], 'readSettings');
      expect(find.text('HTTP 200'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('effectiveDays'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('effectiveDays'), findsWidgets);
      expect(find.textContaining('automaticCleanupPaused'), findsWidgets);
      expect(find.textContaining('"error":"apply"'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
