import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/download_directory.dart';
import 'package:localsend_app/util/native/native_path.dart';
import 'package:test/test.dart';

void main() {
  Future<String> resolve(TargetPlatform platform, {String? downloads, Map<String, String> env = const {}, String documents = '/sandbox/Documents'}) =>
      resolveDefaultDownloadDirectory(
        platform: platform,
        systemDownloads: () async => downloads,
        applicationDocuments: () async => documents,
        environment: env,
      );

  for (final (platform, value) in [
    (TargetPlatform.linux, '/mnt/资料/My Downloads'),
    (TargetPlatform.macOS, '/Volumes/Data/下载 %20 # '),
    (TargetPlatform.android, '/storage/emulated/10/Download'),
    (TargetPlatform.windows, r'D:\资料\My Downloads'),
    (TargetPlatform.windows, r'\\nas\user downloads\资料'),
    (TargetPlatform.windows, r'\\?\D:\long\下载'),
    (TargetPlatform.windows, r'\\?\UNC\nas\share\下载'),
  ]) {
    test('$platform preserves the system download location byte for byte: $value', () async {
      expect(await resolve(platform, downloads: value), value);
    });
  }

  test('Windows fallback retains the drive and prefers USERPROFILE', () async {
    expect(
      await resolve(TargetPlatform.windows, env: {'USERPROFILE': r'E:\Users\Legna', 'HOMEDRIVE': 'D:', 'HOMEPATH': r'\Users\Other'}),
      r'E:\Users\Legna\Downloads',
    );
    expect(await resolve(TargetPlatform.windows, env: {'HOMEDRIVE': 'D:', 'HOMEPATH': r'\Users\Legna'}), r'D:\Users\Legna\Downloads');
    expect(await resolve(TargetPlatform.windows, env: {'USERPROFILE': r'\\server\profile\user'}), r'\\server\profile\user\Downloads');
  });

  test('Windows rejects drive-relative, root-relative and device namespace roots', () async {
    for (final root in [r'\Downloads', '/Downloads', 'C:Downloads', 'C:', r'\\server', r'\\.\PIPE\service', r'\\?\GLOBALROOT\Device']) {
      expect(isFullyQualifiedNativePath(root, windows: true), false, reason: root);
      await expectLater(resolve(TargetPlatform.windows, downloads: root), throwsA(isA<FileSystemException>()));
    }
    await expectLater(resolve(TargetPlatform.windows, env: {'HOMEPATH': r'\Users\Legna'}), throwsA(isA<FileSystemException>()));
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    test('$platform falls back only to HOME/Downloads, not HOME', () async {
      expect(await resolve(platform, env: {'HOME': '/home/legna'}), '/home/legna/Downloads');
      await expectLater(resolve(platform, env: {'HOME': 'relative'}), throwsA(isA<FileSystemException>()));
      await expectLater(resolve(platform), throwsA(isA<FileSystemException>()));
    });
  }

  test('iOS uses Files-visible app Documents/Downloads, never guesses Safari or iCloud', () async {
    expect(
      await resolve(TargetPlatform.iOS, downloads: '/must-not-use', documents: '/sandbox/Application/UUID/Documents'),
      '/sandbox/Application/UUID/Documents/Downloads',
    );
    expect(await resolve(TargetPlatform.iOS, documents: '/new-sandbox/Documents'), '/new-sandbox/Documents/Downloads');
    await expectLater(resolve(TargetPlatform.iOS, documents: 'relative'), throwsA(isA<FileSystemException>()));
  });

  test('Android never guesses profile zero or treats SAF as a filesystem path', () async {
    for (final downloads in [null, '', 'content://documents/tree/primary%3ADownload', 'relative']) {
      await expectLater(resolve(TargetPlatform.android, downloads: downloads, env: {'HOME': '/wrong'}), throwsA(isA<FileSystemException>()));
    }
  });

  test('failed system query uses a valid desktop fallback without filesystem writes', () async {
    expect(
      await resolveDefaultDownloadDirectory(
        platform: TargetPlatform.windows,
        systemDownloads: () => throw const FileSystemException('fixture lookup failure'),
        applicationDocuments: () => throw StateError('Not used on desktop'),
        environment: {'USERPROFILE': r'C:\Users\fixture'},
      ),
      r'C:\Users\fixture\Downloads',
    );
  });

  test('local paths are not decoded, trimmed or expanded as URIs or shell text', () async {
    for (final windows in [true, false]) {
      for (final value in ['', 'relative', '~/Downloads', r'$HOME/Downloads', 'file:///tmp/path', 'content://provider/tree/id', '/a\x00b']) {
        expect(isFullyQualifiedNativePath(value, windows: windows), false, reason: value);
      }
    }
    expect(isFullyQualifiedNativePath('/tmp/name:part\\tail ', windows: false), true);
    expect(await resolve(TargetPlatform.linux, downloads: '/tmp/%2e%2e/用户 # ? '), '/tmp/%2e%2e/用户 # ? ');
  });
}
