#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
xcrun swiftc app/ios/Runner/IosWorkspaceGrantStore.swift app/ios/Runner/IosReceiveGrantStore.swift \
  app/test/native/ios_receive_grant_store_test.swift -o "$TMP/receive-grants"
"$TMP/receive-grants"
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios14.0-simulator app/ios/Runner/IosWorkspaceGrantStore.swift \
  app/ios/Runner/IosReceiveGrantStore.swift app/ios/Runner/IosWorkspaceFolderPicker.swift
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios14.0-simulator \
  -F .fvm/flutter_sdk/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator \
  -import-objc-header app/ios/Runner/Runner-Bridging-Header.h app/ios/Runner/*.swift
printf 'iOS Simulator SDK: %s\n' "$(xcrun --sdk iphonesimulator --show-sdk-version)"
plutil -lint app/ios/Runner.xcodeproj/project.pbxproj
