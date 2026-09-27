import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/native/android_workspace_documents.dart';
import 'package:localsend_app/util/workspace/workspace_catalog.dart';
import 'package:localsend_app/util/workspace/workspace_directory_probe.dart';

import 'workspace_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  const tree = 'content://documents.example/tree/opaque%3Aroot';
  const source = WorkspaceSource(kind: WorkspaceSourceKind.androidTree, locator: tree);
  final requests = <Map<String, dynamic>>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    requests.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'workspaceDocuments');
      requests.add(jsonDecode((call.arguments as Map)['request'] as String));
      return {
        'payload': jsonEncode({'version': 1, 'readable': true}),
      };
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('probe preserves opaque tree identity without inventing filesystem path', () async {
    final result = await probeWorkspaceDirectory(source);
    expect(result.isValid, true);
    expect(result.canonicalPath, isNull);
    expect(result.documentTree, tree);
    expect(result.verifiedLocator, tree);
    expect(requests.single['op'], 'probe');
    expect(requests.single['tree'], tree);
    expect(requests.single['version'], 1);
    expect(requests.single['generation'], 0);
  });

  test('write enable checks authority without acquiring a grant and persists only success', () async {
    final original = workspace(1, enabled: true).copyWith(source: source);
    final store = MemoryWorkspaceStore([original]);
    final catalog = WorkspaceCatalog(store: store);
    await catalog.initialize();
    final before = catalog.state.entries.single;
    for (final writable in [null, false, 'true']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'payload': jsonEncode({'version': 1, 'readable': true, 'writable': writable}),
        },
      );
      await expectLater(catalog.setAllowUpload(original.id, true), throwsA(isA<PlatformException>()));
      expect(catalog.state.entries.single, before);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      requests.add(jsonDecode((call.arguments as Map)['request'] as String));
      return {
        'payload': jsonEncode({'version': 1, 'readable': true, 'writable': true}),
      };
    });
    final enabled = await catalog.setAllowUpload(original.id, true);
    expect(enabled.allowUpload, true);
    expect(enabled.generation, before.generation + 1);
    expect(requests.every((request) => request['op'] == 'probe'), true);
    expect((await catalog.update(original.id, name: 'Renamed')).allowUpload, true);
    await catalog.disable(original.id);
    final changed = await catalog.update(
      original.id,
      source: const WorkspaceSource(kind: WorkspaceSourceKind.androidTree, locator: 'content://documents.example/tree/another-root'),
    );
    expect(changed.allowUpload, false);
  });

  test('remote write changes cannot probe the device before claiming management authority', () async {
    var writeChecks = 0;
    final original = workspace(1, enabled: true).copyWith(source: source);
    final catalog = WorkspaceCatalog(
      store: MemoryWorkspaceStore([original]),
      writeProbe: (_) async {
        writeChecks++;
      },
    );
    await catalog.initialize();
    await expectLater(
      catalog.manage(
        id: original.id,
        generation: catalog.state.entries.single.generation,
        action: WorkspaceManagementAction.update,
        claim: () async => false,
        allowUpload: true,
      ),
      throwsA(isA<WorkspaceManagementException>()),
    );
    expect(writeChecks, 0);
    await catalog.manage(
      id: original.id,
      generation: catalog.state.entries.single.generation,
      action: WorkspaceManagementAction.update,
      claim: () async => true,
      allowUpload: true,
    );
    expect(writeChecks, 1);
    expect(catalog.state.entries.single.allowUpload, true);
  });

  test('revoked permission and malformed availability fail closed', () async {
    for (final reply in [
      null,
      {'payload': '{}'},
      {'payload': '{"version":1,"readable":false}'},
      {'payload': '[]'},
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => reply);
      expect((await probeWorkspaceDirectory(source)).isValid, false);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'GRANT_UNAVAILABLE');
    });
    expect((await probeWorkspaceDirectory(source)).invalidReason, WorkspaceInvalidReason.grantUnavailable);
  });

  test('provider errors distinguish missing folders, revoked access and loading failures', () async {
    for (final (code, reason) in [
      ('not_found', WorkspaceInvalidReason.missing),
      ('permission', WorkspaceInvalidReason.permissionDenied),
      ('loading', WorkspaceInvalidReason.ioError),
      ('busy', WorkspaceInvalidReason.ioError),
      ('cancelled', WorkspaceInvalidReason.timeout),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code);
      });
      expect((await probeWorkspaceDirectory(source)).invalidReason, reason);
    }
  });

  test('probe timeout requests cancellation for its own request, not the tree', () async {
    final blocked = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final request = jsonDecode((call.arguments as Map)['request'] as String) as Map<String, dynamic>;
      requests.add(request);
      if (request['op'] == 'probe') return blocked.future;
      return null;
    });
    await expectLater(const AndroidWorkspaceDocuments(timeout: Duration(milliseconds: 10)).probe(tree), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(requests.map((e) => e['op']), ['probe', 'cancel']);
    expect(requests.last['requestId'], requests.first['requestId']);
    expect(requests.last.containsKey('tree'), false);
    blocked.complete({'payload': '{"version":1,"readable":true}'});
    await Future<void>.delayed(Duration.zero);
  });

  test('catalog publishes document locators and refuses uploads without a verified write grant', () async {
    final original = workspace(1, enabled: true).copyWith(source: source);
    final store = MemoryWorkspaceStore([original]);
    final catalog = WorkspaceCatalog(store: store);
    await catalog.initialize();
    expect(catalog.state.publishable.single.source, source);
    expect(catalog.state.verifiedLocators[original.id], tree);
    await expectLater(catalog.setAllowUpload(original.id, true), throwsA(isA<PlatformException>()));
    await expectLater(
      catalog.manage(
        id: original.id,
        generation: catalog.state.entries.single.generation,
        action: WorkspaceManagementAction.update,
        claim: () async => true,
        allowUpload: true,
      ),
      throwsA(isA<PlatformException>()),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'GRANT_UNAVAILABLE');
    });
    final reopened = WorkspaceCatalog(store: store);
    await reopened.initialize();
    expect(reopened.state.publishable, isEmpty);
    expect(reopened.state.entries.single.enabled, false);
    expect(reopened.state.entries.single.invalidReason, WorkspaceInvalidReason.grantUnavailable);
  });

  test('catalog rejects fake filesystem success or a different document grant', () async {
    for (final result in [
      const WorkspaceProbeResult.valid('/fake/path'),
      const WorkspaceProbeResult.documents('content://documents.example/tree/other'),
    ]) {
      final catalog = WorkspaceCatalog(
        store: MemoryWorkspaceStore([workspace(1, enabled: true).copyWith(source: source)]),
        probe: (_) async => result,
      );
      await catalog.initialize();
      expect(catalog.state.publishable, isEmpty);
    }
  });

  test('non-Android and invalid URI sources never invoke a document provider', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(const AndroidWorkspaceDocuments().probe(tree), throwsUnsupportedError);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final invalid in ['/storage/root', 'content://documents.example/document/file', '$tree?query=x', '$tree#fragment']) {
      await expectLater(const AndroidWorkspaceDocuments().probe(invalid), throwsFormatException);
    }
    expect(requests, isEmpty);
  });
}
