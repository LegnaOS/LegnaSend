# Native receive retention settings

## User-facing behavior

Settings → Receive includes an interrupted receive cache retention selector:

- Automatic cleanup (default when the preference has never been set).
- Keep until manually cleaned.
- Keep for 1, 7 or 30 days.

The displayed effective policy is the native process acknowledgement, not an optimistic preference value. English, Simplified Chinese, Traditional Chinese (Taiwan and Hong Kong), and English fallback are provided. The adjacent receive-cache maintenance dialog explicitly previews and confirms manual cleanup regardless of retention age. Workspace export cleanup has its own adjacent entry and independent private-storage rules.

Retention applies only to registered native receive files left after an unexpected process exit. Normal cancellation and transfer failure still immediately remove their transaction cache. Workspace uploads, workspace export copies and Android document-provider transactions are separate. Keeping a cache does not provide partial resume for the original LocalSend protocol. A timed policy makes an entry eligible on the next maintenance pass; it is not an exact-time deletion timer.

## Persistence and failure handling

`legnasend_receive_cache_retention_days` stores `0` for automatic cleanup, `-1` for manual retention, or a positive day count. The UI offers the five presets above; existing valid custom values up to 3650 days remain representable. Missing preferences default to automatic cleanup. An existing malformed type or value falls back to manual retention, displays a damaged-policy error, and pauses automatic native cleanup until the setting is repaired.

Startup applies the saved policy before receive-cache registry initialization and the startup cleanup sweep. A failed synchronization does not silently use the native process's immediate-cleanup default. Automatic native cleanup pauses while applying a policy or while its effective state is unknown. Android provider reconciliation continues independently.

Changes persist before applying to native code. A failed save does not invoke native configuration. Apply failure restores the previous preference where possible and queries the actual native policy. Failed preference recovery is visible and leaves automatic native cleanup paused. The UI offers retry and continues to display the actual confirmed policy. The controller accepts one operation at a time; provider disposal prevents a late completion from reenabling cleanup.

## Manual maintenance boundary

Only the explicitly confirmed receive-cache dialog uses `inspectReceiveCacheRegistryNow` / `cleanupReceiveCacheRegistryNow`. Read-only inspection performs no removal. Automatic startup cleanup, general temporary-cache cleanup, and API cache maintenance keep using the ordinary retention-aware operations. Manual override bypasses age only, never identity, header, source or active-writer protection. An in-flight automatic pass and a manual pass do not share a misleading result: the latter waits, then performs its own pass.

## Verification

Targeted shared-Flutter tests cover persisted presets, malformed preferences, failed save/apply/recovery, native acknowledgement parsing, unknown runtime state, retry, concurrent changes and disposal. Four locale widgets exercise selection and visible failure at 360 px with 1.4× text. Maintenance tests cover automatic/manual serialization and independent provider reconciliation. Native retention and process-kill evidence are documented separately in [Native receive retention](NATIVE_RECEIVE_RETENTION.md).

These tests are shared-code and desktop-host evidence, not Android/iOS physical-device storage acceptance.

## Scoped remote settings

The settings API now exposes saved retention and acknowledged native state through the same controller as this UI. API writes use global keyed settings permission, strict integer input and snapshot-version checks; they do not perform cleanup. Read/failed-write recovery and offline examples are documented in the [retention API guide](API_RECEIVE_RETENTION.md).
