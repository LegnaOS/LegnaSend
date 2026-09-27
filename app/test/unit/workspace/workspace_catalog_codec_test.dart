import 'dart:convert';

import 'package:localsend_app/model/persistence/directory_workspace.dart';
import 'package:localsend_app/util/workspace/workspace_catalog_codec.dart';
import 'package:test/test.dart';

import 'workspace_fixtures.dart';

void main() {
  test('versioned roundtrip keeps stable identity and Unicode display name', () {
    final entries = [workspace(1), workspace(2, enabled: true, visible: false)];
    final decoded = WorkspaceCatalogCodec.decode(WorkspaceCatalogCodec.encode(entries));
    expect(decoded, entries);
    expect(() => decoded.add(workspace(3)), throwsUnsupportedError);
    expect(WorkspaceCatalogCodec.decode(null), isEmpty);
  });

  test('schema 1 migrates without weakening schema 2 password intent', () {
    final original = workspace(1).toJson()..remove('passwordHash');
    final migrated = WorkspaceCatalogCodec.decode(
      jsonEncode({
        'version': 1,
        'workspaces': [original],
      }),
    );
    expect(migrated.single.passwordHash, isNull);
    final secured = migrated.single.copyWith(passwordHash: fixturePasswordHash);
    final encoded = WorkspaceCatalogCodec.encode([secured]);
    expect(jsonDecode(encoded)['version'], 4);
    expect(WorkspaceCatalogCodec.decode(encoded).single.passwordHash, fixturePasswordHash);
    expect(secured.toString(), isNot(contains(fixturePasswordHash)));
    expect(
      () => WorkspaceCatalogCodec.decode(
        jsonEncode({
          'version': 1,
          'workspaces': [secured.toJson()],
        }),
      ),
      throwsFormatException,
    );
  });
  test('password verifier shape and work factor are strict and errors are redacted', () {
    for (final value in ['plaintext-private-secret', fixturePasswordHash.replaceFirst('600000', '1'), '$fixturePasswordHash=']) {
      expect(() => WorkspaceCatalogCodec.encode([workspace(1).copyWith(passwordHash: value)]), throwsFormatException);
    }
  });

  test('platform grant locators remain distinct from ordinary paths', () {
    final android = workspace(1).copyWith(
      source: const WorkspaceSource(
        kind: WorkspaceSourceKind.androidTree,
        locator: 'content://documents/tree/primary%3ADownload',
      ),
    );
    final apple = workspace(2).copyWith(
      source: const WorkspaceSource(
        kind: WorkspaceSourceKind.appleBookmark,
        locator: '/external/Docs',
        grantId: 'grant-reference',
      ),
    );
    expect(WorkspaceCatalogCodec.decode(WorkspaceCatalogCodec.encode([android, apple])), [android, apple]);
    expect(() => WorkspaceCatalogCodec.encode([apple.copyWith.source(grantId: null)]), throwsFormatException);
    expect(() => WorkspaceCatalogCodec.encode([android.copyWith.source(locator: '/just/a/path')]), throwsFormatException);
  });

  test('strict route grammar rejects traversal, reserved names and encodings', () {
    for (final slug in [
      '',
      'api',
      'assets',
      'i18n',
      '../secret',
      '%2e%2e',
      'a/b',
      'a\\b',
      'a%2fb',
      'a?b',
      'a#b',
      'a.b',
      'Name',
      '-name',
      'name-',
      'a b',
      '文档',
      'workspace1\n',
    ]) {
      expect(() => WorkspaceCatalogCodec.encode([workspace(1).copyWith(slug: slug)]), throwsFormatException, reason: slug);
    }
    expect(WorkspaceCatalogCodec.normalizeSlug(' WorkSPACE-1 '), 'workspace-1');
    expect(WorkspaceCatalogCodec.decode(WorkspaceCatalogCodec.encode([workspace(1).copyWith(slug: 'workspace-1')])), hasLength(1));
  });

  test('duplicate IDs and routes fail closed instead of shadowing each other', () {
    expect(() => WorkspaceCatalogCodec.encode([workspace(1), workspace(1).copyWith(slug: 'another')]), throwsFormatException);
    expect(() => WorkspaceCatalogCodec.encode([workspace(1), workspace(2).copyWith(slug: 'workspace1')]), throwsFormatException);
  });

  test('upload permission is strict, opt-in and migrated read-only', () {
    final original = workspace(1).toJson()..remove('allowUpload');
    for (final version in [1, 2]) {
      final rows = WorkspaceCatalogCodec.decode(
        jsonEncode({
          'version': version,
          'workspaces': [original],
        }),
      );
      expect(rows.single.allowUpload, false);
      final forged = {...original, 'allowUpload': true};
      expect(
        () => WorkspaceCatalogCodec.decode(
          jsonEncode({
            'version': version,
            'workspaces': [forged],
          }),
        ),
        throwsFormatException,
      );
    }
    final allowed = workspace(1).copyWith(allowUpload: true);
    expect(WorkspaceCatalogCodec.decode(WorkspaceCatalogCodec.encode([allowed])).single.allowUpload, true);
    for (final value in ['true', 1, null]) {
      expect(
        () => WorkspaceCatalogCodec.decode(
          jsonEncode({
            'version': 3,
            'workspaces': [
              {...original, 'allowUpload': value},
            ],
          }),
        ),
        throwsFormatException,
      );
    }
  });

  test('unknown schema and fields are not silently discarded on save', () {
    for (final raw in ['{}', '', '[]', '{"version":4,"workspaces":[]}', '{"version":1,"workspaces":[],"future":true}']) {
      expect(() => WorkspaceCatalogCodec.decode(raw), throwsFormatException);
    }
    final document = jsonDecode(WorkspaceCatalogCodec.encode([workspace(1)])) as Map<String, dynamic>;
    document['workspaces'][0]['passwordPolicy'] = 'future-feature';
    expect(() => WorkspaceCatalogCodec.decode(jsonEncode(document)), throwsFormatException);
  });

  test('booleans and generations are never coerced from strings or numbers', () {
    for (final (field, value) in [('enabled', 'true'), ('visible', 1), ('generation', 1.5), ('generation', '2'), ('name', 42)]) {
      final row = workspace(1).toJson()..[field] = value;
      expect(
        () => WorkspaceCatalogCodec.decode(
          jsonEncode({
            'version': 1,
            'workspaces': [row],
          }),
        ),
        throwsFormatException,
      );
    }
  });

  test('bad names, IDs, locators and enable states fail validation', () {
    final base = workspace(1);
    for (final entry in [
      base.copyWith(id: 'reused-name'),
      base.copyWith(name: ''),
      base.copyWith(name: ' trailing '),
      base.copyWith(name: 'new\nline'),
      base.copyWith.source(locator: 'a\x00b'),
      base.copyWith(generation: 0),
      base.copyWith(generation: 0x1fffffffffffff),
      base.copyWith(enabled: true, invalidReason: WorkspaceInvalidReason.missing),
    ]) {
      expect(() => WorkspaceCatalogCodec.encode([entry]), throwsFormatException);
    }
  });

  test('input budgets reject oversized catalogs before model conversion', () {
    expect(() => WorkspaceCatalogCodec.encode(List.generate(WorkspaceCatalogCodec.maxEntries + 1, workspace)), throwsFormatException);
    expect(() => WorkspaceCatalogCodec.decode(' ' * (WorkspaceCatalogCodec.maxEncodedLength + 1)), throwsFormatException);
  });

  test('parsing exceptions do not echo private configuration', () {
    try {
      WorkspaceCatalogCodec.decode('{private-secret-path');
      fail('expected parse failure');
    } catch (error) {
      expect(error.toString(), isNot(contains('private-secret-path')));
    }
  });
}
