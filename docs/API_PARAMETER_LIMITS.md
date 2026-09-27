# API parameter limits and workspace state

## Fixed mismatch

The read-only `getWorkspaceState` contract advertised an 8192-byte ID list, but the native console and explorer field each stopped at 4096. The HTTP parser also limited the entire encoded query to 8192 bytes, leaving no room for `generation`, parameter names or escaped commas at the documented maximum.

The integration contract, console and query parser now share bounded parameter rules:

| Input | Bound |
|---|---|
| Workspace-state `ids` | At most 8192 ASCII bytes and 64 comma-separated nonempty ID tokens |
| Workspace anchor `anchor` | At most 8192 URL-safe base64 ASCII bytes; one entry in the requested directory |
| Ordinary decoded parameters | At most 4096 UTF-8 bytes |
| File-list filter | At most 256 Unicode scalar values, also subject to the byte budget |
| Console `Range` / `If-Match` | At most 1024 bytes |
| Encoded integration workspace-state query | At most 24 KiB |
| Encoded query on other integration routes | Existing 8 KiB limit |
| Local console workspace-state JSON envelope | At most 24 KiB, accommodating JSON escaping of bounded fields |
| Other console envelopes | Existing limits, including the separate workspace-send allowance |

The ID list accepts only letters, digits, `_`, `-` and separator commas. It does not introduce local paths, arbitrary URLs or target selection. Canonical base64url decoding, uniqueness, parent-directory matching, source access, authorization and generation checks remain in the existing read-only directory handler. `POST` remains rejected. No route, permission, original LocalSend field or handshake was added or changed.

## Contract and explorer

String schemas declare `maxLength`, measured in Unicode scalar values, plus `x-legnasend-max-utf8-bytes`. Operations declare `x-legnasend-max-query-bytes`. The four supported contract languages explain the 64-ID/8192-byte boundary. The explorer reads those limits rather than hard-coding every field to 4096, surfaces schema descriptions, and validates `minLength`, `maxLength`, `pattern`, enum and numeric constraints before execution. Invalid control characters and unpaired surrogates are rejected.

Encoded query size is distinct from decoded field size. Dart URI rendering and Rust form encoding differ for `~` and `*`; the explorer checks both representations when validating a draft so its copied URL and console request both fit the server limit. Incomplete or invalid example templates still require correction before external use. Existing envelope, response and concurrency budgets remain independent.

## Verification

- Real authenticated HTTP and the real local HTTP console both read 64 canonical missing IDs at exact 4096- and 8192-byte list sizes; results match. An 8193-byte list is rejected. Ordinary query limits, traversal/absolute/URL path rejection and GET-only behavior remain covered.
- Seven core console tests pass, including localized live contract assertions, UTF-8/scalar limits, encoded query boundaries and exact 4096/8192 cases.
- Four parameter unit tests cover Unicode, schema composition, both query encodings and oversized inputs.
- Four explorer page tests cover English, Simplified Chinese, Traditional Chinese and Hong Kong Chinese at 390 pixels with 1.6× text. A complete 8192-character draft reaches the read-only console unchanged; a programmatically oversized draft does not dispatch.

This is a bounded read-interface correctness fix, not a new file-management capability or physical mobile acceptance. The root batch owns regenerated OpenAPI snapshots and bundled documentation synchronization.

Directory listing now shares the 24 KiB encoded-query envelope so an 8192-byte anchor, a UTF-8 relative path, filter and generation fit together. Other route budgets remain unchanged.
