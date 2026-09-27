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
import '../unit/api/api_transfer_explorer_test.dart' show device, version, requestId, transferOperationFixture;

class _Catalog extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async => jsonEncode({
    'paths': {
      '/transfers/send': {'post': transferOperationFixture('sendSelection')},
      '/devices': {'get': transferOperationFixture('listDevices')},
      '/workspaces/{workspaceId}/send': {
        'post': {
          ...transferOperationFixture('sendWorkspaceFiles'),
          'parameters': [
            {
              'name': 'workspaceId',
              'in': 'path',
              'required': true,
              'schema': {'type': 'string', 'format': 'uuid'},
            },
          ],
        },
      },
      '/transfers/{transferId}/retry': {'post': transferOperationFixture('retryTransfer')},
    },
    'components': {'schemas': {}},
  });
  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

class _Server extends ApiTestServer {
  final calls = <Map<String, dynamic>>[];
  _Server() {
    this.fail = true;
  }
  @override
  Future<String> integrationApiRequest({required int expectedGeneration, required String request}) async {
    calls.add(jsonDecode(request));
    if (this.fail) throw StateError('transport interrupted');
    return jsonEncode({'status': 202, 'body': '{"transferId":"$device"}'});
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _Server server, AppLocale locale) async {
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
            bundle: _Catalog(),
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
    final target = find.byKey(ValueKey(key));
    // Lazy children above the viewport may be evicted after executing a request.
    // Search missing controls from the start, not farther down past them.
    if (key.startsWith('api-operation-') || target.evaluate().isEmpty) {
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      await tester.pumpAndSettle();
    }
    if (target.evaluate().isEmpty) await tester.scrollUntilVisible(target, 200, scrollable: find.byType(Scrollable).first, maxScrolls: 40);
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

  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw]) {
    testWidgets('send confirmation and failure retain draft ${locale.languageTag}', (tester) async {
      final server = _Server();
      await mount(tester, server, locale);
      await tap(tester, 'api-operation-sendSelection');
      await enter(tester, 'api-body-deviceId', device);
      await enter(tester, 'api-body-selectionVersion', version);
      await enter(tester, 'api-body-requestId', requestId);
      await tap(tester, 'api-execute');
      expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsOneWidget);
      expect(server.calls, isEmpty);
      await tap(tester, 'api-transfer-decline');
      expect(server.calls, isEmpty);
      await tap(tester, 'api-execute');
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls, hasLength(1));
      expect(server.calls.single['body'], {'deviceId': device, 'selectionVersion': version, 'requestId': requestId});
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tap(tester, 'api-operation-listDevices');
      await tap(tester, 'api-operation-sendSelection');
      await reveal(tester, 'api-body-requestId');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('api-body-requestId'))).controller!.text, requestId);
      server.fail = false;
      await tap(tester, 'api-execute');
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls, hasLength(2));
      expect(server.calls.last, server.calls.first);
      await tap(tester, 'api-transfer-new-request');
      expect(find.byKey(const ValueKey('api-transfer-new-request-confirmation')), findsOneWidget);
      await tap(tester, 'api-transfer-new-request-confirm');
      await reveal(tester, 'api-body-requestId');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('api-body-requestId'))).controller!.text, isNot(requestId));
      expect(server.calls, hasLength(2));
      await tap(tester, 'api-operation-retryTransfer');
      await enter(tester, 'api-param-transferId', device);
      await enter(tester, 'api-body-requestId', requestId);
      await tap(tester, 'api-execute');
      expect(find.textContaining('LocalSend'), findsWidgets);
      expect(
        find.textContaining(
          locale == AppLocale.en
              ? 'All files in the original task'
              : locale == AppLocale.zhCn
              ? '原任务的全部文件'
              : '原工作的全部檔案',
        ),
        findsOneWidget,
      );
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls.last['operation'], 'retryTransfer');
      expect(server.calls.last['parameters'], {'transferId': device});
      expect(server.calls.last['body'], {'requestId': requestId});
      expect(tester.takeException(), isNull);
    });
  }
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
    testWidgets('document source choice, draft and exact request ${locale.languageTag} at 390px 1.6x', (tester) async {
      final server = _Server();
      await mount(tester, server, locale);
      await tap(tester, 'api-operation-sendWorkspaceFiles');
      await reveal(tester, 'api-body-sourceMode');
      final mode = find.byKey(const ValueKey('api-body-sourceMode'));
      expect(tester.state<FormFieldState<String>>(mode).value, '');
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text(ApiTransferStrings(locale.languageTag).documentSource).last);
      await tester.pumpAndSettle();
      expect(tester.state<FormFieldState<String>>(mode).value, 'documentSnapshot');
      await enter(tester, 'api-param-workspaceId', device);
      await enter(tester, 'api-body-instanceId', version);
      await enter(tester, 'api-body-generation', '3');
      await enter(tester, 'api-body-deviceId', device);
      await enter(tester, 'api-body-requestId', requestId);
      final selectedFiles = jsonEncode([
        {'id': version},
      ]);
      await enter(tester, 'api-body-files', selectedFiles);
      await tap(tester, 'api-execute');
      expect(find.byKey(const ValueKey('api-transfer-confirmation')), findsOneWidget);
      expect(server.calls, isEmpty);
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls, hasLength(1));
      expect(server.calls.single['operation'], 'sendWorkspaceFiles');
      expect(server.calls.single['parameters'], {'workspaceId': device});
      expect(server.calls.single['body'], {
        'instanceId': version,
        'generation': 3,
        'deviceId': device,
        'requestId': requestId,
        'sourceMode': 'documentSnapshot',
        'files': [
          {'id': version},
        ],
      });
      await tap(tester, 'api-operation-listDevices');
      await tap(tester, 'api-operation-sendWorkspaceFiles');
      await reveal(tester, 'api-body-sourceMode');
      expect(tester.state<FormFieldState<String>>(mode).value, 'documentSnapshot');
      await reveal(tester, 'api-body-files');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('api-body-files'))).controller!.text, selectedFiles);
      await reveal(tester, 'api-body-requestId');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('api-body-requestId'))).controller!.text, requestId);
      server.fail = false;
      await tap(tester, 'api-execute');
      await tap(tester, 'api-transfer-confirm');
      expect(server.calls, hasLength(2));
      expect(server.calls.last, server.calls.first);
      expect(tester.takeException(), isNull);
    });
  }
}
