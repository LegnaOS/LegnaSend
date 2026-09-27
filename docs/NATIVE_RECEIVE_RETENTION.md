# Native receive crash-residue retention

## Scope

This preference governs **registered, unlocked native receive remnants left after a process crash or a failed cleanup**. It does not enable native resume, change LocalSend v2 endpoints or messages, or retain files after an ordinary cancellation: the existing transaction drop still removes its owned temporary files. Restarting a transfer against an original peer remains a whole-file retry.

Directory-upload staging and Android SAF cleanup keep their separate lifecycles. The preference never scans Downloads for `.ls` suffixes and never removes a final destination or an unregistered file. A registered native `.ls` cache or native export `.part` staging file is eligible only after the existing ownership checks pass.

## Stable native bridge interface

All methods are asynchronous; blocking registry maintenance runs on a Rust worker. Existing method signatures remain unchanged.

| Dart method | Result and semantics |
| --- | --- |
| `configureReceiveCacheRetentionPolicy(mode: ..., days: ...)` | JSON policy; validates before replacing the effective process policy. |
| `getReceiveCacheRetentionPolicy()` | Current effective policy JSON, without reading or changing cache payloads. |
| `cleanupReceiveCacheRegistry(limit: ...)` | Existing cleanup, now respecting the effective retention policy. |
| `inspectReceiveCacheRegistry(limit: ...)` | Existing read-only inventory, respecting that policy. |
| `cleanupReceiveCacheRegistryNow(limit: ...)` | Explicit local user override of age retention only. |
| `inspectReceiveCacheRegistryNow(limit: ...)` | Read-only preview of the explicit age override. |

Policy JSON always contains `mode` and `days`:

```json
{"mode":"immediate","days":null}
```

```json
{"mode":"days","days":7}
```

```json
{"mode":"manual","days":null}
```

`days` mode accepts 1–3650 days. The other modes require absent/null days. Unknown modes, zero, excessive days and extraneous day values fail without changing the previous policy. The application owns persistence and must configure the native policy before automatic cleanup. Native configuration is valid before registry setup. The process default remains immediate cleanup, preserving existing behavior.

Configuration waits for a running maintenance batch to release its policy read lock, so a successful configuration return does not race with an old-policy batch that is still unlinking files. A batch remains limited by its existing entry/time budget. The local explicit override does not change the configured policy. Startup maintenance and general API cache clearing retain the policy-respecting entry point; they do not silently become age overrides.

## Registration age and compatibility

The private receipt gains optional `registered_unix_ms`, set from the receiver's system clock at registration. Cleanup uses this persisted value, not the remote file metadata, cache identity timestamp, receipt modification time, or startup time. Reopening the registry does not reset age. An elapsed day is exactly 86,400 seconds; the cache becomes eligible at the exact configured boundary.

Old receipts without a timestamp remain readable and checksum-valid: an absent optional field stays absent during serialization. Days-based cleanup retains them rather than inventing an age. Immediate cleanup and an explicit local override preserve the previous cleanup eligibility rules. Missing clock values or a clock reading earlier than the registration time also retain the file. This is a process-crash recovery record, not a new power-loss durability guarantee or a resumable transfer manifest.

## Safety precedence and report reasons

Existing checks run first: valid receipt/source/checksum, active registration lock, parent and file identity, regular-file checks, active payload lock, and cache header identity. Retention never masks an active or unverifiable file. A verified parent whose registered temporary filename is already absent can still have its obsolete receipt retired in every policy; an unavailable parent remains protected.

The report shape, opaque identifiers and dispositions are unchanged. Paths, peer identities, session credentials and registration timestamps are not added to the public report. Retained entries report zero planned deletion bytes. New stable reason strings are:

| Reason | Meaning |
| --- | --- |
| `retention_period` | Verified native remnant has not reached the configured age. |
| `retention_manual` | Verified native remnant is retained until explicit local cleanup. |
| `retention_age_unknown` | Days mode found a legacy/clock-unavailable registration with no timestamp. |
| `retention_clock_unverified` | Current time is missing or predates registration. |

## Verification

- 23 registry unit tests pass, including seven retention-specific tests with injected clock values, actual persisted receipts/reopen, old checksum compatibility, exact age boundary, clock rollback, configuration failure atomicity, active locks, changed identities, invalid headers and absent receipts.
- Four original native HTTP cache tests pass: full-file retry/checksum behavior, cancellation, stalled bodies, disconnects and server stop remain intact.
- Two process-fixture tests pass: a real HTTP child writes a registered partial cache, active cleanup and explicit override skip it, forced child termination releases locks, manual and one-day policies retain it, and an explicit override removes only its registered remnant. User `.ls` and published files remain unchanged.
- One real rebuilt-bridge test passes: getter/configuration validation and unchanged policy after an invalid configuration, both explicit override calls while active, ordinary cancellation under manual retention, and a subsequent successful native transfer.
- Optional strict whole-core Clippy (`-- -D warnings`) reports 32 existing diagnostics in unchanged crypto, HTTP client/server and WebRTC files; no diagnostic targets this retention module. The strict whole-core lint gate is not marked passing.

These are core/macOS host checks. They do not close physical Android/iOS acceptance or add native partial-resume support.
