#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/legnasend-macos-grants.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
xcrun swiftc app/ios/Runner/IosWorkspaceGrantStore.swift app/test/native/ios_workspace_grant_store_test.swift -o "$TMP/shared-grants"
"$TMP/shared-grants"
xcrun swiftc app/ios/Runner/IosWorkspaceGrantStore.swift app/test/native/macos_workspace_grant_store_test.swift -o "$TMP/macos-grants"
"$TMP/macos-grants"
FRAMEWORK=".fvm/flutter_sdk/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
for ARCH in arm64 x86_64; do
  xcrun swiftc -typecheck -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$ARCH-apple-macosx10.15" \
    -F "$FRAMEWORK" app/ios/Runner/IosWorkspaceGrantStore.swift app/macos/Runner/MacosWorkspaceGrants.swift
  echo "macOS $ARCH: actual FlutterMacOS channel and shared grant store typecheck passed"
done
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios14.0-simulator \
  app/ios/Runner/IosWorkspaceGrantStore.swift app/ios/Runner/IosWorkspaceFolderPicker.swift
plutil -lint app/macos/Runner.xcodeproj/project.pbxproj
python3 - <<'PY'
from pathlib import Path
store = Path('app/ios/Runner/IosWorkspaceGrantStore.swift').read_text()
channel = Path('app/macos/Runner/MacosWorkspaceGrants.swift').read_text()
project = Path('app/macos/Runner.xcodeproj/project.pbxproj').read_text()
assert 'URL.BookmarkCreationOptions = [.withSecurityScope]' in store
assert 'URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]' in store
assert '#if os(macOS)' in store and 'URL.BookmarkCreationOptions = [.minimalBookmark]' in store
assert 'panel.canChooseFiles = false' in channel and 'panel.canChooseDirectories = true' in channel
assert 'guard response == .OK else { reply(nil); return }' in channel
assert 'legnasend/ios_workspace' in channel and 'private let queue = DispatchQueue' in channel
for method in ('pick', 'probe', 'acquire', 'retainOnly', 'release', 'adopt', 'prune', 'discard'):
    assert 'case "' + method + '":' in channel
assert 'path = ../ios/Runner/IosWorkspaceGrantStore.swift; sourceTree = SOURCE_ROOT;' in project
assert 'MacosWorkspaceGrants.swift in Sources' in project
print('PASS: macOS security-scope flags, complete private channel, cancellation, serial access and shared source registration guards')
PY
