# Optional native same-session receive resume

> This document preserves the original same-session baseline. Negotiated durable recovery is now described in the [durable extension contract](NATIVE_DURABLE_RESUME.md), including verification, suspend and cleanup. Statements below excluding restart recovery apply to the original mode without durable negotiation.

This developer contract describes the implemented LegnaSend extension, version 1. It is **not the administrative bearer-token API**, a replacement for LocalSend v2, browser-download recovery, or a persistent cross-restart transfer protocol.

## Negotiation and eligibility

First complete the unchanged LocalSend v2 prepare/approval handshake. Use its accepted `sessionId`, `fileId` and **file-specific** `token`. No new mandatory prepare field or endpoint is required of an original LocalSend peer.

The sender considers ordinary regular files of at least **1 MiB (1,048,576 bytes)**, opened at offset zero. It opens the source and snapshots size/modification metadata before probing, then computes the full SHA-256 only after capability succeeds. Small files, streams and unsupported source descriptors retain whole-file behavior. A changed source fails rather than silently switching to different bytes.

The receiver advertises only files explicitly approved for an ordinary persistent cache-path destination. Gallery post-processing, Android SAF/content URIs and Android SD-card provider destinations retain original v2 whole-file transfer. At 1 MiB per block, the current cache limit is 1,048,576 blocks: at most **1 TiB**.

Only a **capability** response with HTTP **404, 405 or 501** selects fallback to original `POST /api/localsend/v2/upload`, with the original raw file body. Authentication errors, timeouts, malformed capabilities, hash errors and later resume failures do not cause that fallback. A successful capability must contain `version: 1`, `supported: true` and `blockSize: 1048576`; a successful response saying `supported: false` is not the current unsupported signal.

## Authentication and common query

Base path: `/api/legnasend/v1/receive-resume/`.

Every request carries URL-encoded `sessionId`, `fileId` and `token`. The receiver also matches the original sender's peer IP (including IPv6 scope where applicable) and TLS certificate fingerprint. HTTP has no certificate identity, but still requires the approved peer and token. HTTPS requests use the same pinned, route-bound client as the original native transfer. An administrator bearer key does not grant access to these endpoints.

`block`, `status`, `finish` and `abort` additionally require `resumeId`, returned by `open`; `block` also requires decimal `offset`. Query keys are allowlisted per operation. Duplicate/empty fields, unknown keys, values above 4096 bytes, or a raw query above 16 KiB are rejected. Treat tokens and query strings as sensitive; do not put them in diagnostic logs.

## Six operations

| Method and suffix | Request | Successful response |
|---|---|---|
| `GET capabilities` | Common query; no body | Capability JSON |
| `POST open` | Common query; JSON `size`, `sha256` | Receipt JSON |
| `PUT block` | Common query + `resumeId`, `offset`; raw bytes; `X-LegnaSend-Block-Sha256` | Receipt after committed block |
| `GET status` | Common query + `resumeId` | Current receipt, or 409 while an operation owns the entry |
| `POST finish` | Common query + `resumeId`; no body needed | Receipt with `state: "complete"` after verified publication |
| `POST abort` | Common query + `resumeId`; no body needed | `{"version":1,"state":"cancelling"}`, or the complete receipt if already published |

Capability:

```json
{"version":1,"supported":true,"blockSize":1048576}
```

Open body (replace the illustrative digest with the actual full-file SHA-256):

```json
{"size":2097153,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
```

`size` must equal the approved v2 file size. If the original DTO supplied a checksum, it must match too. The SHA-256 is mandatory here even when omitted in the original prepare DTO; exactly 64 hexadecimal characters are accepted and normalized to lowercase. Unknown JSON fields are rejected; open body budget is 1024 bytes with a 10-second body deadline.

Receipt:

```json
{
  "version":1,
  "resumeId":"11111111-1111-4111-8111-111111111111",
  "blockSize":1048576,
  "offset":1048576,
  "size":2097153,
  "sha256":"0000000000000000000000000000000000000000000000000000000000000000",
  "state":"receiving"
}
```

Returned receipt states are `ready`, `receiving`, and `complete`. Initial setup reports 409 until ready; failed/cancelled/expired entries report 410 instead of a resumable receipt. Repeating `open` with the same authenticated session/file/size/hash reuses the entry and does not allocate another target. A different identity returns 409.

## Block and recovery rules

- Send exactly `min(1048576, size - offset)` bytes; no multipart envelope or aggregate file format. Offsets advance sequentially and must equal the receiver's committed offset. Every non-final offset is block-aligned.
- The block header is SHA-256 of those raw bytes, not the whole file. Wrong length returns 400 and cancels that entry; a mismatching block hash returns 422 and cancels it. Oversized bodies return 413. Body collection has a 60-second deadline.
- Only one operation owns an entry at a time. Busy `status`/write requests return 409. Do not interpret that as a lost checkpoint or permission to create a new session.
- If a block/finish response is lost, query `status` before sending more data. A committed block may outlive its HTTP connection. An unchanged offset permits retry of the uncommitted block; an advanced offset skips confirmed bytes. Do not blindly resend an already committed offset: it returns 409.
- The current sender allows up to three shared reconnect/busy backoffs (1, 2 and 4 seconds), with cancellation checks. Open may be retried idempotently; block/finish transport errors or 409 reconcile through status. Each resume HTTP request has a 30-second timeout, and success/error response bodies have an 8192-byte budget.
- The sender rejects mismatched resume ID/size/hash/block size, invalid alignment, decreasing checkpoints, status offsets beyond the last possible submitted block, acknowledgements that do not end at the submitted block boundary, and finish replies that are not complete. It never converts these failures into whole-file fallback.

## Publication, cancellation and lifetime

Receiving bytes or reaching `offset == size` is **not final success**. `finish` verifies the full cached content, exports original bytes to owned staging, and publishes without overwriting an existing destination. Cache/staging cleanup occurs before the final success reply. The cache is a `.ls` file beside the destination; it is not the delivered file format or a new legacy wire format.

An interrupted HTTP request does not itself cancel its accepted file. The receiver retains the in-memory transaction during the short recovery window. Its worker expires after **60 seconds since initialization/last committed block**, checked between operations; polling `status` does not extend the window. Target acquisition also has a 60-second bound. A blocking operating-system publication is not forcibly undone at an arbitrary timer deadline.

Sender transfer failure/cancellation after acquiring a valid resume ID attempts `abort` for that file, with a two-second best-effort budget. It does not send a session-wide cancel for sibling files. Explicit original session cancellation or listener stop revokes the associated resume entries. Aborting an already completed entry returns its completed receipt; it does not delete the delivered file.

Successful completion receipts retain authentication and metadata, **not target descriptors**, for approximately 60 seconds after transaction finalization so a lost finish response can be reconciled. Server stop/session revocation may remove them sooner. The registry is bounded to 72 entries, with at most eight receive-cache workers shared with ordinary cached receiving. Capacity exhaustion returns 429.

Useful errors: 400 invalid request/body, 403 identity/token rejection, 404 unsupported capability or unknown operation, 408 body deadline, 409 busy/checkpoint/identity conflict, 410 missing/revoked/expired entry, 413 body budget, 422 block digest mismatch, 429 capacity, and 500 setup/storage/publication failure. Some cancellation races return 410 rather than a final receipt; obtain actual state rather than infer a published file from bytes sent.

## Explicit non-goals and evidence

No reconstruction of a live session/resume ID after app or listener restart is implemented. A newly approved session is a fresh attempt. Existing startup cleanup manages owned inactive remnants; durable `.ls` records alone do not imply wire-level restart recovery. SAF/gallery destinations and provider-backed resume are not implemented by this extension. Files remain sequential within a resume transaction; this is not parallel block upload.

Implementation: `packages/core/src/http/{client/resumable_upload.rs,server/receive_resume.rs}`, `server/common/receive_cache.rs`, and `packages/localsend_isolates/lib/src/task/server/receive_resume_capability.dart`.


An abort acknowledgement means cancellation was requested, not that a racing disk publication was undone. If publication already succeeded, retain the actual saved outcome and never remove the delivered file.

## Source-end control extension

This optional durable extension is an exception to the common session-query rules above. It does not change any required LocalSend v2 fields or endpoints.

Capability example:

```json
{"version":1,"supported":true,"blockSize":1048576,"durable":{"version":1,"sourceEnd":{"version":1}}}
```

An opted-in durable open adds `"sourceEnd":1` inside `recovery`; without it the old open shape and behavior remain valid. Once the target/record is verified, its receipt adds:

```json
{"sourceEnd":{"version":1,"grantId":"GRANT_UUID","round":"ROUND_UUID","token":"BASE64URL_32_RANDOM_BYTES","expiresAtUnixMs":1800000000000}}
```

The initial `verifying` receipt may omit this field. A supporting sender must wait until the grant is received and durably persisted before transmitting its first block. The current private host acknowledgement is bounded by 30 seconds and cancellation. No grant is inferred from a recovery key. Explicit unsupported negotiation is distinct from an unanswered request.

`POST /api/legnasend/v1/receive-resume/source-end` uses **no query parameters**, with JSON body:

```json
{"version":1,"requestId":"REQUEST_UUID","grantId":"GRANT_UUID","round":"ROUND_UUID","token":"BASE64URL_32_RANDOM_BYTES"}
```

The body limit is 4096 bytes with a five-second body deadline. UUIDs must be canonical. Unknown fields, malformed secrets and queries are rejected. TLS uses the original pinned client and the receiver matches the saved peer certificate; without TLS the exact saved IP must match. Keep this secret out of URLs, logs and the public administration API.

HTTP 200 contains a **typed outcome**, not unconditional success:

```json
{"outcome":"cleared","receiptId":"RECEIPT_UUID","removedFiles":1,"unlinkedBytes":1049000}
```

Outcomes are `cleared`, `publishedPreserved`, `active`, `publicationPending`, `retainedUnknown`, `unknownOrExpired`, `superseded`, and `authorizationRequired`. Only `cleared` is a cleanup receipt. `publishedPreserved` means no published destination was deleted. Other outcomes preserve uncertainty or protection and must not become a deletion-success message. The receipt field is nullable; protected/unknown responses have zero deletion counters. Repeated valid grants replay the original durable receipt, including its counters; they do not count another deletion. A transport failure remains an unknown response, not a typed result.

Cleanup takes the real inactive record lock and verifies the exact round, cache transaction and file identities. New attachment supersedes old authority. An old grant cannot remove a new attachment; an active or publishing operation is not force-cancelled. Final published files are never deletion targets. The original record expiry is absolute and is not extended by retries. Control admission is bounded to four real workers and 256 ledger entries; unavailable capacity is not permission to bypass locks or change to an older endpoint.
