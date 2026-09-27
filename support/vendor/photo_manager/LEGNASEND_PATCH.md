# LegnaSend local compatibility patch

Upstream: [photo_manager 3.12.0](https://pub.dev/packages/photo_manager/versions/3.12.0).

The published archive was downloaded and SHA-256 verified against the pub.dev API. `../flutter_plugins.lock.json` records the archive digest, modified-file hashes and the original license hash. Every retained upstream file was compared to that archive; only files in the recorded patch differ. `LEGNASEND.patch` contains the exact delta. The upstream version and LICENSE are unchanged.

## Changes

- Restrict CocoaPods source globs to h/m/mm/swift, leaving PrivacyInfo.xcprivacy exclusively in the existing privacy resource bundle; apply to all three published Darwin layouts. Swift Package Manager resource settings are unchanged.
- Complete Objective-C model nullability. Constructor IDs are non-null; model object fields that may be unset remain nullable, as do optional PhotoKit collection/title inputs. No runtime or Dart API change.

- Compile legacy image-data and open-settings fallbacks only when the deployment target can run them; preserve older-platform support without compiling deprecated unreachable calls for this app.

## Scope and maintenance

This is an app-local path dependency, not an upstream release. Examples, example build outputs and upstream agent instructions were omitted; runtime sources, package manifests, licenses, upstream release notes and available unit tests remain. Do not edit the pub cache or generated Pods. Re-evaluate these patches against a future upstream release before removing the path override.

Native checks and integration-build results are recorded in `docs/evidence/apple-build-warnings/` at the repository root.
