# Receiver-confirmed source cleanup receipts

## Implementation status

Source implementation is present; automated tests, analysis, builds and runtime acceptance were deliberately deferred at the user's request. No new platform acceptance is claimed. The existing optional source-end extension and original LocalSend transfer protocol are unchanged.

## Product behavior

- Source-end notices retain the receiver's receipt ID, actual removed temporary-file count and logical unlinked bytes instead of discarding the result after reducing it to a status.
- A compact list summary is displayed only when an itemized receiver receipt exists. Selecting a notice opens an in-page dialog containing status, exact logical bytes and a selectable receipt ID.
- The dialog explicitly distinguishes logical removed-file size from measured physical disk space reclaimed. The numbers describe temporary files, not published destination files.
- Published files remain labeled as preserved. If a receiver confirms temporary-file cleanup while preserving a published file, only the temporary-file counters are displayed.
- Pending, unknown, expired, unsupported, shared-source, authorization and busy states do not receive invented zero counters. Older terminal notices without a receipt remain readable and display that itemized receipt data is absent.
- English, Simplified Chinese and Traditional Chinese text is included; Hong Kong uses the Traditional Chinese copy, matching the existing source-end locale helper.

## Persistence and disclosure

The private version-1 outbox gains an optional `cleanup` object without changing its required fields:

```json
{
  "receiptId": "11111111-1111-4111-8111-111111111111",
  "removedFiles": 1,
  "unlinkedBytes": 4096
}
```

This example is illustrative, not measured evidence. The source-end result already carries these values; neither file size nor download progress is used to reconstruct them. Missing old data is never backfilled with zeros.

Only `removed` and `publishedPreserved` states accept the object. The receipt is a canonical UUID v4; count is an integer from zero through two, matching the existing per-source receiver ledger. Byte count is nonnegative; zero removed files requires zero unlinked bytes. A malformed terminal result leaves cleanup unconfirmed instead of publishing malformed proof. A stale callback is still rejected by the existing notice-version check. New grants and retry transitions discard prior receipt data; late local completion preserves a receipt already recorded from the receiver.

The public native-task notice projection includes only `receiptId`, `removedFiles` and `unlinkedBytes`. These values are not cleanup authority. Grants, tokens, resume keys, paths and route metadata remain private. The nested public projection is immutable, and existing notice-count and encoded-response limits remain in force.

## API compatibility

`GET /native-tasks/source-end` and the retry response can include optional `cleanup`. The server validates the exact object shape and terminal state; unrelated or secret fields are rejected. Existing notices without `cleanup` remain valid. No endpoint, required request field, scope or original transfer format changes.

The Rust OpenAPI source and four `docs/api` snapshots were edited together as source/data changes, without invoking a test-based exporter. The normal offline-document synchronization remains part of the enclosing batch.

## Deferred verification

- Restart a journal after a real removal receipt and confirm exact counters and no capability disclosure.
- Preserve version-1 journals and public responses without receipt data, including old terminal notices.
- Exercise malformed receipt, mismatched outcome, stale callback and uncertain journal write paths.
- Confirm a published-file result never becomes a published-file deletion claim; distinguish a real zero receipt from missing data.
- Check OpenAPI snapshot equality, exact public-response validation, bounded response size and retry replay behavior.
- Check in-page detail, selectable ID, narrow screens, larger text and all four supported locale tags.
- Run actual receiver cleanup and compare receipt counts with logical sizes of the removed temporary files; measure physical space separately if required.
