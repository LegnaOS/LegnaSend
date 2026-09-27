import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';

class ConsoleServer extends ApiTestServer {
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
  Future<void> mount(WidgetTester tester, ConsoleServer server, AppLocale locale, double width, double scale) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: [locale.flutterLocale],
            locale: locale.flutterLocale,
            theme: ThemeData(colorSchemeSeed: const Color(0xff54b865), brightness: locale == AppLocale.en ? Brightness.light : Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const ApiExplorerPage(),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-search')), findsOneWidget);
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(target, 180, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  for (final (locale, width, scale) in [
    (AppLocale.en, 1040.0, 1.0),
    (AppLocale.zhCn, 390.0, 1.0),
    (AppLocale.zhHk, 390.0, 1.6),
    (AppLocale.de, 390.0, 1.0),
  ]) {
    testWidgets(
      'catalog, validation, real service callback and bounded result ${locale.languageTag} $width $scale',
      (tester) async {
        final server = ConsoleServer();
        await mount(tester, server, locale, width, scale);
        await tester.enterText(find.byKey(const ValueKey('api-search')), 'listRequests');
        await tester.pumpAndSettle();
        expect(find.byWidgetPredicate((w) => w is ListTile && w.key.toString().contains('api-operation-')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('api-operation-listRequests')));
        await tester.pumpAndSettle();
        final token = find.byKey(const ValueKey('api-console-token'));
        await reveal(tester, token);
        await tester.enterText(token, 'fixture-private-token');
        expect(tester.widget<TextField>(token).obscureText, true);
        final limit = find.byKey(const ValueKey('api-param-limit'));
        await reveal(tester, limit);
        await tester.enterText(limit, '101');
        final execute = find.byKey(const ValueKey('api-execute'));
        await reveal(tester, execute);
        await tester.tap(execute);
        await tester.pumpAndSettle();
        expect(server.calls, isEmpty);
        expect(find.text(t.apiExplorer.invalid), findsOneWidget);
        await tester.ensureVisible(limit);
        await tester.enterText(limit, '2');
        await reveal(tester, execute);
        await tester.tap(execute);
        await tester.pump();
        expect(server.calls.single['operation'], 'listRequests');
        expect(server.calls.single['parameters'], {'after': '0', 'limit': '2'});
        expect(server.calls.single['token'], 'fixture-private-token');
        expect(tester.widget<FilledButton>(execute).onPressed, isNull);
        server.response.complete(
          jsonEncode({
            'status': 200,
            'elapsedMs': 2,
            'bytes': 36,
            'headers': {'content-type': 'application/json'},
            'body': '{"entries":[],"nextAfter":1}',
            'binary': false,
            'truncated': false,
          }),
        );
        await tester.pumpAndSettle();
        await reveal(tester, find.text('HTTP 200'));
        expect(find.text('HTTP 200'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
  testWidgets('closing the page ignores a late request failure', (tester) async {
    final server = ConsoleServer();
    await mount(tester, server, AppLocale.en, 390, 1);
    await tester.enterText(find.byKey(const ValueKey('api-search')), 'getStatus');
    await tester.pumpAndSettle();
    final execute = find.byKey(const ValueKey('api-execute'));
    await reveal(tester, execute);
    await tester.tap(execute);
    await tester.pump();
    expect(server.calls.length, 1);
    await tester.pumpWidget(const SizedBox());
    server.response.completeError(StateError('fixture failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
