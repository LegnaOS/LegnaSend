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
import 'package:localsend_app/util/api/api_upload_source.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../unit/api/api_fixtures.dart';

class _Catalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/workspaces/{workspaceId}/upload': {
        'post': {
          'operationId': 'uploadFile',
          'summary': 'Upload a selected file',
          'parameters': [
            {
              'name': 'workspaceId',
              'in': 'path',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'generation',
              'in': 'query',
              'required': true,
              'schema': {'type': 'integer', 'minimum': 1},
            },
            {
              'name': 'path',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'directory',
              'in': 'query',
              'required': false,
              'schema': {'type': 'boolean', 'default': false},
            },
          ],
          'responses': {
            '201': {'description': 'Published'},
            '409': {'description': 'Conflict'},
          },
        },
      },
    },
    'components': {'schemas': <String, dynamic>{}},
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
  Future<void> mount(WidgetTester tester, _Server server, Future<ApiUploadSource?> Function() picker, {AppLocale locale = AppLocale.en}) async {
    const fontPath = String.fromEnvironment('API_UPLOAD_SCREENSHOT_FONT');
    if (fontPath.isNotEmpty) {
      await tester.runAsync(() async {
        final font = FontLoader('ApiEvidenceFont')..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
        await font.load();
        const iconPath = String.fromEnvironment('API_UPLOAD_SCREENSHOT_ICONS');
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
        key: const ValueKey('api-upload-capture'),
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
                  fontFamily: fontPath.isEmpty ? null : 'ApiEvidenceFont',
                ),
                debugShowCheckedModeBanner: false,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.35)),
                  child: child!,
                ),
                home: ApiExplorerPage(pickUploadSource: picker),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-operation-uploadFile')));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> parameters(WidgetTester tester) async {
    for (final (key, value) in [('workspaceId', 'workspace-id'), ('generation', '4'), ('path', '目标/file.bin')]) {
      await reveal(tester, 'api-param-$key');
      await tester.enterText(find.byKey(ValueKey('api-param-$key')), value);
    }
  }

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhHk]) {
    testWidgets(
      'selected source requires confirmation, cancellation is inert and failed POST remains visible ${locale.languageTag}',
      (tester) async {
        final server = _Server();
        var selections = 0;
        final source = ApiUploadSource(name: '中文 %.bin', path: '/private/SELECTED_SOURCE.bin', size: 123456789);
        await mount(tester, server, () async {
          selections++;
          return source;
        }, locale: locale);
        await parameters(tester);
        await reveal(tester, 'api-upload-pick');
        await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
        await tester.pumpAndSettle();
        expect(selections, 1);
        expect(find.byKey(const ValueKey('api-upload-source')), findsOneWidget);
        await reveal(tester, 'api-execute');
        await tester.tap(find.byKey(const ValueKey('api-execute')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('api-upload-confirmation')), findsOneWidget);
        const capture = String.fromEnvironment('API_UPLOAD_SCREENSHOTS');
        if (capture.isNotEmpty) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('api-upload-capture')));
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await Directory(capture).create(recursive: true);
              await File('$capture/api-upload-${locale.languageTag}-${defaultTargetPlatform.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        expect(server.calls, isEmpty);
        expect(find.textContaining('/private/SELECTED_SOURCE'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('api-upload-decline')));
        await tester.pumpAndSettle();
        expect(server.calls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('api-execute')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('api-upload-confirm')));
        await tester.pump();
        expect(server.calls.single['operation'], 'uploadFile');
        expect(server.calls.single['head'], false);
        expect(server.calls.single['uploadPath'], source.path);
        expect(server.calls.single['uploadSize'], source.size);
        expect(server.calls.single['parameters'], {'workspaceId': 'workspace-id', 'generation': '4', 'path': '目标/file.bin', 'directory': 'false'});
        server.response.complete(
          jsonEncode({'status': 409, 'elapsedMs': 4, 'bytes': 8, 'headers': {}, 'body': 'Conflict', 'binary': false, 'truncated': false}),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('HTTP 409'), 180, scrollable: find.byType(Scrollable).first);
        expect(find.text('HTTP 409'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
    );
  }
  testWidgets('picker cancellation keeps the page usable and missing source does not send', (tester) async {
    final server = _Server();
    await mount(tester, server, () async => null);
    await parameters(tester);
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-upload-source')), findsNothing);
    expect(find.byKey(const ValueKey('api-console-error')), findsNothing);
    await reveal(tester, 'api-execute');
    await tester.tap(find.byKey(const ValueKey('api-execute')));
    await tester.pumpAndSettle();
    expect(server.calls, isEmpty);
    expect(find.byKey(const ValueKey('api-upload-confirmation')), findsNothing);
    expect(find.byKey(const ValueKey('api-console-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty directory sends no selected path and request failure is handled', (tester) async {
    final server = _Server();
    await mount(tester, server, () async => throw StateError('must not pick'));
    await parameters(tester);
    await reveal(tester, 'api-upload-empty-directory');
    await tester.tap(find.byKey(const ValueKey('api-upload-empty-directory')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-upload-pick')), findsNothing);
    await reveal(tester, 'api-execute');
    await tester.tap(find.byKey(const ValueKey('api-execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-upload-confirm')));
    await tester.pump();
    expect(server.calls.single['parameters']['directory'], 'true');
    expect(server.calls.single.containsKey('uploadPath'), false);
    expect(server.calls.single.containsKey('uploadUri'), false);
    server.response.completeError(StateError('connection ended'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('api-console-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late picker completion after page close holds no native descriptor or request', (tester) async {
    final server = _Server(), picker = Completer<ApiUploadSource?>();
    await mount(tester, server, () => picker.future);
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    picker.complete(const ApiUploadSource(name: 'selected', path: 'content://opaque/id', size: 42));
    await tester.pump();
    expect(server.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
