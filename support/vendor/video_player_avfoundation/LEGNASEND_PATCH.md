# LegnaSend local compatibility patch

Upstream: [video_player_avfoundation 2.11.0](https://pub.dev/packages/video_player_avfoundation/versions/2.11.0).

The published archive was downloaded and SHA-256 verified against the pub.dev API. `../flutter_plugins.lock.json` records the archive digest, modified-file hashes and the original license hash. Every retained upstream file was compared to that archive; only files in the recorded patch differ. `LEGNASEND.patch` contains the exact delta. The upstream version and LICENSE are unchanged.

## Changes

- Match FlutterPlatformViewFactory's platform-specific createArgsCodec result: nullable on macOS, non-null on iOS. The actual codec remains non-null on both platforms.
- Mirror Apple's AVF_DEPRECATED_FOR_SWIFT_ONLY availability on the Objective-C status wrapper so importing its header into Swift does not incorrectly expose a non-deprecated method returning a Swift-deprecated type. Objective-C asynchronous loading behavior is unchanged; no compiler-warning suppression flag is added.

## Scope and maintenance

This is an app-local path dependency, not an upstream release. Examples, example build outputs and upstream agent instructions were omitted; runtime sources, package manifests, licenses, upstream release notes and available unit tests remain. Do not edit the pub cache or generated Pods. Re-evaluate these patches against a future upstream release before removing the path override.

Native checks and integration-build results are recorded in `docs/evidence/apple-build-warnings/` at the repository root.
