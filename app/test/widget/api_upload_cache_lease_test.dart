import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/api_explorer_page.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/api/api_upload_source.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
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
  Future<RefenaContainer> mount(WidgetTester tester, _Server server, Future<ApiUploadSource?> Function() picker) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
    final container = RefenaContainer(overrides: [serverProvider.overrideWithNotifier((_) => server)]);
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        ownsContainer: false,
        container: container,
        child: TranslationProvider(
          child: DefaultAssetBundle(
            bundle: _Catalog(),
            child: MaterialApp(
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: [AppLocale.en.flutterLocale],
              home: ApiExplorerPage(pickUploadSource: picker),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-operation-uploadFile')));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> expectProtected(RefenaContainer container, bool protected) async {
    var cleaned = false;
    await container
        .read(sourceCacheLeaseProvider)
        .cleanIfIdle(
          inUse: () => false,
          cleanup: () async {
            cleaned = true;
          },
        );
    expect(cleaned, !protected);
  }

  const source = ApiUploadSource(name: 'file.bin', path: '/cache/picked.bin', size: 10);

  testWidgets('source picker waits until an already running cleanup finishes', (tester) async {
    var picked = false;
    final container = await mount(tester, _Server(), () async {
      picked = true;
      return source;
    });
    final cleanup = Completer<void>();
    final cleaning = container.read(sourceCacheLeaseProvider).cleanIfIdle(inUse: () => false, cleanup: () => cleanup.future);
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pump();
    expect(picked, false);
    cleanup.complete();
    await cleaning;
    await tester.pumpAndSettle();
    expect(picked, true);
    await expectProtected(container, true);
    await tester.pumpWidget(const SizedBox());
    await expectProtected(container, false);
  });

  testWidgets('pending picker lease survives disposal until native picker settles', (tester) async {
    final picked = Completer<ApiUploadSource?>();
    final container = await mount(tester, _Server(), () => picked.future);
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pump();
    await expectProtected(container, true);
    await tester.pumpWidget(const SizedBox());
    await expectProtected(container, true);
    picked.complete(source);
    await tester.pumpAndSettle();
    await expectProtected(container, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft survives cancelled replacement and releases when cleared', (tester) async {
    var selections = 0;
    final container = await mount(tester, _Server(), () async => selections++ == 0 ? source : null);
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pumpAndSettle();
    await expectProtected(container, true);
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pumpAndSettle();
    await expectProtected(container, true);
    expect(find.byKey(const ValueKey('api-upload-source')), findsOneWidget);
    await reveal(tester, 'api-operation-uploadFile');
    await tester.tap(find.byKey(const ValueKey('api-operation-uploadFile')));
    await tester.pumpAndSettle();
    await expectProtected(container, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-flight upload retains independent lease after page disposal', (tester) async {
    final server = _Server();
    final container = await mount(tester, server, () async => source);
    for (final (key, value) in [('workspaceId', 'workspace-id'), ('generation', '4'), ('path', 'file.bin')]) {
      await reveal(tester, 'api-param-$key');
      await tester.enterText(find.byKey(ValueKey('api-param-$key')), value);
    }
    await reveal(tester, 'api-upload-pick');
    await tester.tap(find.byKey(const ValueKey('api-upload-pick')));
    await tester.pumpAndSettle();
    await reveal(tester, 'api-execute');
    await tester.tap(find.byKey(const ValueKey('api-execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-upload-confirm')));
    await tester.pump();
    expect(server.calls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await expectProtected(container, true);
    server.response.completeError(StateError('sender disconnected'));
    await tester.pumpAndSettle();
    await expectProtected(container, false);
    expect(tester.takeException(), isNull);
  });
}
