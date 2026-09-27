# Native recovery across approved tasks

This optional extension keeps the original LocalSend v2 handshake, required fields, certificate checks and original-byte file output. It is separate from the administrative bearer-token API and browser download manager. An original LocalSend peer requires no changes.

## User flow and eligibility

The sending queue saves a random recovery key for each file before using durable recovery. Retrying the whole task or one unfinished file inherits that file's key; a newly selected task receives new keys. Restoring the queue does not automatically send anything. Each retry obtains a new original-v2 approval and new file token before looking for previously confirmed blocks.

Both peers must support the optional capability. The receiver must approve an ordinary persistent filesystem destination with supported directory/file identity and exclusive locks. The source must be a seekable regular file of at least 1 MiB. Gallery, temporary cache and Android SAF targets do not advertise durable recovery; their existing compatible transfer path remains. The receiver checks target capability before approval. Source size and full SHA-256 must still match; a recovery key alone proves neither identity nor authorization.

## Wire contract

Use the same base and authenticated query as [same-session recovery](NATIVE_RESUME_PROTOCOL.md): `/api/legnasend/v1/receive-resume/`. Peer IP, current session/file token and TLS certificate identity remain checked. An administrative bearer key is not sufficient.

The existing capability optionally adds:

```json
{"version":1,"supported":true,"blockSize":1048576,"durable":{"version":1}}
```

Only after observing `durable.version == 1` and successfully persisting its per-file key does the sender add `recovery` to `POST open`:

```json
{"size":2097153,"sha256":"ACTUAL_64_HEX_SHA256","recovery":{"version":1,"resumeKey":"11111111-1111-4111-8111-111111111111"}}
```

Without durable negotiation the old two-field open body is unchanged, including for older LegnaSend receivers that reject unknown fields. Original peers use their original v2 upload after an unsupported capability response. Authentication, malformed contract or changed-source errors never trigger silent whole-file fallback.

The open receipt keeps the existing fields and adds `verifiedBytes`. A durable open may promptly return `state: "verifying", offset: 0` while checking the prior cache or published output. Poll `GET status` using the **new** resume ID. Block/finish requests during verification receive 409. Verification progress is independent of transferred bytes: it is never a valid upload offset or network rate. Once verified, `ready`/`receiving` reports the continuous committed prefix, not the sum of arbitrary present chunks; `complete` requires a full final-file hash.

`POST suspend` takes the common query plus current `resumeId`, with no body. It checkpoints and releases the actual transaction before returning `state: "suspended"`. This operation is durable-only. Existing `abort` destroys an attached owned partial attempt; it does not delete a delivered output. A detached lease is not reclaimable through an obsolete session/token. Resume requires a fresh approval, while local maintenance can remove inactive owned leases.

A successful block is still exactly the existing 1 MiB block (or shorter final block), with its SHA-256 header. Files are not aggregated and blocks within one file remain sequential. The cache file is never sent as the final file.

## Verification, interruption and lifetime

Transport retries retain bounded reconnect behavior. Durable verification has separate cancellable polling with a 30-minute sender deadline, not the three ordinary reconnect backoffs. Source hashing and receiver verification have their own progress stage; restored offsets rebase speed sampling rather than creating a throughput spike.

If reconnect attempts are exhausted, the sender attempts a file-local suspend. It distinguishes a confirmed retained checkpoint from an unknown outcome. An unknown suspend acknowledgement does not permit a later generic v2 cancel: the two connections can reorder and delete a checkpoint in transition. Explicit active cancellation and detected source changes still abort. A successful prior publication remains successful even if its acknowledgement was lost.

Reservations have an absolute **one-day lease**, at most **128 records**, in a private host registry. Status requests and new approvals do not extend that deadline. Source identity, approved destination identity/name, owned cache identity and all committed blocks are rechecked before adoption. Missing birthtime/lock support disables this extension rather than weakening identity. A changed source invalidates only its verified owned old cache; unrelated or replaced files are preserved.

Crash recovery does not restore wire credentials or a live server session. The new attempt reopens the owned journal under an exclusive process lock. Publication intent and a persistent receipt UUID are recorded before final acknowledgement. A lost-ACK retry verifies the owned final output and reuses the receipt, avoiding a numbered duplicate or duplicate history item. Clearing/deleting history persists suppression across restart.

Default orphan cleanup remains separate from valid recovery leases. Startup/API maintenance retains unexpired inactive recovery reservations; the explicitly confirmed local cleanup can remove them earlier. Active locks, published outputs, unknown `.ls` files and identity mismatches remain protected. Expiry becomes effective during a later operation/maintenance pass; it is not a promise of deletion at an exact clock instant.

## Evidence and remaining boundaries

`tests/durable_receive_resume.rs` exercises real HTTP approvals, different tokens/resume IDs, old-session isolation, a confirmed prefix, server replacement, the actual sending client, changed-source cleanup, explicit abort and final-ACK reconciliation. Its explicitly invoked subprocess helper is killed after committing a block; a fresh server recovers that block and verifies final bytes. The helper's ignored flag excludes it from direct suite invocation, not from the parent test.

`tests/receive_resume_registry.rs` covers identity/locks, missing blocks, corrupt final bytes and ownership-safe maintenance. `tests/native_resume_sender.rs` uses an independent wire peer for negotiated and legacy behavior. These are local automated tests, not five-platform physical-device acceptance. Provider-backed durable receive, complete mobile background behavior, and parallel native block uploads remain separate work.

## Typed recovery state

Private application events now distinguish retry waiting, retryable failure, authorization required, source changed and invalid response. Retention is independent: a confirmed checkpoint, an unknown outcome, or no reusable checkpoint for this attempt. The last case is not a receipt that all remote disk data was deleted. Numeric HTTP status is optional; arbitrary response text is never parsed into a permanent source-end decision. Even an original peer's404/410 alone is not enough to assert permanent disappearance.

Waiting reflects actual bounded backoff, including a busy checkpoint, not proof that a network interface disconnected. Verification polling has its own budget and does not increase transfer bytes. Source changes block direct reuse of the old file recovery key; select a new source/send. File and task panels show the same typed state and cancellation clears only its own live waiting indicator.

Android uses a real nonblocking system lock adapter because the pinned Rust standard-library implementation reports Unsupported on that platform. A filesystem explicitly rejecting flock with ENOSYS/EOPNOTSUPP may use whole-file OFD locking; contention never triggers that switch, and explicit unlock uses the actual acquired lock type. Descriptor closure still controls lock lifetime; other platform errors remain failures. The separately negotiated source-end lifecycle below—not these display states or local cancellation—provides authenticated remote cleanup.

## Optional source-end notification

A sender that is offline when a user explicitly ends a source can persist that intent and notify the same receiver later. This is separately negotiated authority, not a reuse of `resumeKey`, an old session/file token, or an administrative bearer key. Ordinary LocalSend peers and durable peers without this capability keep their existing behavior; local cancellation alone never proves remote cache deletion.

The receiver advertises `durable.sourceEnd: {"version":1}`. Only a supporting sender requesting `recovery.sourceEnd:1` receives a `sourceEnd` grant in its ready/status receipt. The grant contains `version`, `grantId`, `round`, a random 32-byte base64url `token`, and `expiresAtUnixMs`. The receiver persists only its hash. Authority is bound to the cache transaction and the original certificate, or exact IP without TLS. Each fresh approved attachment rotates the authority; the record's original one-day absolute deadline is not renewed.

Before sending its first block, the app persists this grant in its separate private journal and acknowledges the exact native upload. Negative acknowledgement, timeout or cancellation sends no first block. Journal I/O uses an opaque native lease with no-follow directory/lock identity checks, a real process lock, and owner-only permissions on Unix. A write failure with an uncertain commit disables further writes until reopening and reading actual disk state. Windows uses the application support directory's inherited private ACL; this is not a claim of tested Windows power-loss durability.

The app saves end intent before dispatch. Shared live references to the same recovery source delay notification; an ended key is not reused for a fresh send. Known peers are rediscovered rather than blindly reusing a stale network address. Temporary connection failures remain pending; unsupported, expired, superseded, unauthorized and unknown outcomes are not deletion receipts. Published files remain protected. A public API retry only schedules this already-authorized private notification and exposes redacted state, never the grant secret or local paths.

The [source-end wire contract](NATIVE_RESUME_PROTOCOL.md#source-end-control-extension) specifies the separate request. The receiver admits at most four actual cleanup workers and retains at most 256 private grant/round/proof entries. Active writers and publication-in-progress are not force-deleted. Successful cleanup is based on identity-checked real unlinks and a durable receipt; exact grant retries replay that receipt. Normal explicit abort, maintenance and expiry preserve a cleanup proof where the grant is still valid. Missing/expired authority without proof returns unknown, never fabricated success.



## iOS coordinated folder recovery (2026-09-27)

External Files receive folders now pass the same persistent-recovery probes while a newly acquired security scope and coordinated accessor are held. Failed permission, identity or locking probes do not advertise durable recovery. A fresh approved session is still required; neither a remembered path nor an old token authorizes a resumed write.

Source-end cleanup authenticates its private ledger before requesting the stored approved root from the host. After authorization it rechecks the grant and directory/file identities. The host keeps access until the actual blocking worker finishes, including HTTP disconnect and listener stop. Expired/manual cleanup and read-only inspection similarly operate under an approved root, with opaque per-record results.

An externally scoped attempt cancelled before a save target is accepted only drops private registry ownership; it does not run target cleanup after the receive scope has drained. Its registered partial content remains available for a fresh approved retry or subsequent coordinated source-end/expiry cleanup.

