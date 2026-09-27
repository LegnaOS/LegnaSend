# LegnaSend local compatibility patch

Upstream: [open_file_mac 1.1.0](https://pub.dev/packages/open_file_mac/versions/1.1.0).

The published archive was downloaded and SHA-256 verified against the pub.dev API. `../flutter_plugins.lock.json` records the archive digest, modified-file hashes and the original license hash. Every retained upstream file was compared to that archive; only files in the recorded patch differ. `LEGNASEND.patch` contains the exact delta. The upstream version and LICENSE are unchanged.

## Changes

- Replace the deprecated multi-URL Launch Services call with the macOS 10.15 asynchronous NSWorkspace configuration API. Return completion on the main queue and report open failures instead of unconditional success; retain the supported single-URL fallback for older macOS.
- Remove unused upstream permission-test helpers, including direct TCC database mutation code, accessibility prompting, disk-access probing, and an unused UTI switch. The active file-open and user folder-selection path remains.

## Scope and maintenance

This is an app-local path dependency, not an upstream release. Examples, example build outputs and upstream agent instructions were omitted; runtime sources, package manifests, licenses, upstream release notes and available unit tests remain. Do not edit the pub cache or generated Pods. Re-evaluate these patches against a future upstream release before removing the path override.

Native checks and integration-build results are recorded in `docs/evidence/apple-build-warnings/` at the repository root.
