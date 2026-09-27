import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  bool enabled(String xml, String name) => RegExp('<key>${RegExp.escape(name)}</key>\\s*<true\\s*/>').hasMatch(xml);

  test('macOS debug/profile and release share network, selected-file and persistent bookmark access', () {
    for (final name in ['DebugProfile', 'Release']) {
      final xml = File('macos/Runner/$name.entitlements').readAsStringSync();
      for (final entitlement in [
        'com.apple.security.app-sandbox',
        'com.apple.security.network.client',
        'com.apple.security.network.server',
        'com.apple.security.files.user-selected.read-write',
        'com.apple.security.files.downloads.read-write',
        'com.apple.security.files.bookmarks.app-scope',
      ]) {
        expect(enabled(xml, entitlement), isTrue, reason: '$name: $entitlement');
      }
    }
  });

  test('release does not inherit debug JIT or disable library validation', () {
    final debug = File('macos/Runner/DebugProfile.entitlements').readAsStringSync();
    final release = File('macos/Runner/Release.entitlements').readAsStringSync();
    expect(enabled(debug, 'com.apple.security.cs.allow-jit'), isTrue);
    for (final exception in ['allow-jit', 'allow-unsigned-executable-memory', 'disable-library-validation']) {
      expect(enabled(release, 'com.apple.security.cs.$exception'), isFalse);
    }
  });
}
