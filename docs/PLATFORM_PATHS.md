# Platform paths

Updated: 2026-09-23. Applies to Linux, macOS, iOS, Android and Windows, including directory workspaces, downloads, future `.ls` caches and integration APIs. This describes the current path foundation, not completed mobile storage support.

## Defaults and native permissions

| Platform | Default native download location | Remaining platform acceptance |
| --- | --- | --- |
| Linux | System Downloads through the installed path provider/XDG configuration; if unavailable, an absolute `$HOME/Downloads` | Custom XDG location, permissions, mounted volumes and actual Linux reads/writes |
| macOS | System Downloads; absolute `$HOME/Downloads` only if the location query fails | Sandbox/security-scoped access, removable volumes and signing-specific behavior |
| Windows | Known Downloads folder first, including a redirected location; fallback to absolute `USERPROFILE/Downloads`, then `HOMEDRIVE` plus `HOMEPATH` plus Downloads | Native Windows, UNC/network shares, long paths, reparse points, offline volumes and access controls |
| Android | The native public Downloads query for the current profile/volume | Scoped storage, SAF tree permissions, persisted grants and real devices; no guessed `/storage/emulated/0` fallback |
| iOS | The app's current `Documents/Downloads`, visible through the app's Files integration | Real Files behavior, provider selection and security-scoped bookmark persistence; this is not Safari/iCloud's Downloads folder |

A chosen destination overrides the default unchanged. An Android `content://` URI is not a disk path. The resolver only finds the location; it does not create a directory or probe it by writing a file. Existing file-save logic creates the destination and reports write errors. A missing Downloads directory no longer silently redirects files to Home. An unresolved destination/cache lookup rejects the current pending upload and presents a localized in-app error; stale lookups do not reject later sessions. Existing iOS files in Documents are not moved or deleted.

## Path representations

- Native roots use the host platform's filesystem semantics. Windows requires a drive-qualified root, complete UNC share or supported extended drive/UNC root; current-drive-relative and device namespace roots are rejected. POSIX and Windows error numbers are mapped independently.
- Preserve Unicode, literal percent signs, spaces and path spelling. Do not trim a selected path, decode it as a URL, expand shell expressions, lowercase it or rewrite every separator to `/`. The native path validator is a qualification gate, not a substitute for actual filesystem permission checks.
- Android trees and Apple bookmark references remain distinct source kinds. Unsupported/missing grants remain disabled with a typed reason; a saved URI or absolute path does not establish persistent access.
- Workspace browser/API paths use `/` independently of the host OS. Encode the directory query once; treat returned file IDs and cursors as opaque. Native roots are never published in the index/list API. File reads use the verified directory handle and recheck confinement.
- Current directory routes exclude descendant symlinks/special files, internal `.ls`/`.legnasend*` names and unsupported components, including backslashes, colons, control characters, dot components, trailing spaces/dots and Windows device names. This portable route namespace is narrower than the host filesystem. Do not claim that every possible native filename is currently shared.
- The original LocalSend endpoints, file-name fields, handshakes and transferred bytes are unchanged. Do not send workspace locators or `.ls` containers as replacements for the user's original files.

## Verification

The new tests cover platform-parameterized download selection, UNC/extended paths, current-drive rejection, Android profiles/URIs, iOS app-container changes, exact path retention, typed errors, repeated receive failures and stale callbacks. A real local directory HTTP test verifies Unicode/space/percent/hash names and byte ranges without double decoding or exposing the native root.


## Android receive-directory grants and document identity

On 2026-09-24, receive settings/options begin requesting persistent read/write access and validating the persisted grant plus directory creation support before saving a selection. Read-only sharing selection remains read-only. Cancellation is quiet; failures use the existing localized in-page dialog and retain the old setting. Results arriving after page disposal are discarded.

SAF receive traversal starts from the selected tree and checks its persisted grant on each attempt. Query real child document IDs and use the ID returned by createDocument for missing folders; never infer a provider ID from a filesystem-style suffix. Null queries/results, conflicting files, duplicate names, provider-renamed folders, revoked permissions, offline roots and scan limits propagate failure rather than falling back to another location. Validate all components before mutation, cap paths at 128 directories and stream at most 100,000 entries per directory. A serial worker with 32 queued operations keeps traversal off the UI thread. Provider calls are not forcibly time-limited.

Do not retain permission/directory caches across attempts. History uses the actual created file URI. External programs may race queries and creation; no provider atomicity is claimed, and rejected results are not automatically deleted. This internal platform channel does not alter the original v2 wire contract.


## Receive descriptor lifetime

Receive attempts now check session identity before opening a queued target and after asynchronous provider preparation. A descriptor arriving after cancellation or service shutdown is closed, not deleted. Rust adopts descriptor ownership before waiting on request state; rejection, invalid target combinations and unconsumed target channels drop the owned file. The original v2 body and same-token checksum retry remain unchanged. SAF documents still use the direct descriptor writer; complete cache/publication/cleanup transactions remain in the [implementation plan](SAF_RECEIVE_TRANSACTION_PLAN.md).
