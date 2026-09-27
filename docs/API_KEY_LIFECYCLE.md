# Remote API key lifecycle

[中文版](API_KEY_LIFECYCLE_ZH.md)

## Authority and scope

The optional integration API prefix is `/api/legnasend/v1/integration`. Every endpoint in this document requires an enabled, unexpired bearer key explicitly granted `keys.manage` and the wildcard `*` workspace grant. Existing keys receive no new permission automatically. Anonymous grants, workspace passwords and workspace-only keys do not authorize key management.

A manager can list and control only keys whose scopes and workspace grants are subsets of its own. New grants cannot exceed the caller's authority; a child expiry cannot outlive an expiring caller. Resuming an existing key also checks the expiry ceiling. A caller cannot pause, resume or revoke itself. Grant editing and arbitrary verifier import are not exposed. Operations use the same serialized persistence owner as local settings, preventing remote changes from overwriting concurrent local edits.

## Endpoints

| Method | Path | Result |
|---|---|---|
| GET | `/keys` | `{version, keys}`; metadata only |
| POST | `/keys/create` | First success: 201 with receipt and one-time secret |
| POST | `/keys/{keyId}/manage` | Pause, resume or revoke; receipt |
| GET | `/keys/requests/{requestId}` | This caller's durable receipt and application state |

`version` is a 64-character lowercase SHA-256 version of the saved key metadata and receipt set. Treat it as opaque. Metadata includes `id`, `name`, `grant`, `createdAt`, nullable `expiresAt`, `enabled` and nullable `limits`; it never contains a verifier or secret.

### Create

Read `/keys`, retain its version, and generate a fresh UUID request ID for this intent:

```json
{
  "version": "KEYS_VERSION",
  "requestId": "REQUEST_ID",
  "name": "Automation reader",
  "grant": {"scopes": ["service.read", "files.read"], "workspaces": ["WORKSPACE_ID"]},
  "expiresAt": null
}
```

All five fields are required. `expiresAt` is Unix seconds, not milliseconds; null requests no expiry and is accepted only when the caller itself has no expiry. Names are nonempty and at most 256 UTF-8 bytes. The app has at most 128 keys. Unknown fields, paths and caller-provided secrets are rejected.

First successful delivery:

```json
{
  "receipt": {
    "principal": "CALLER_KEY_ID", "requestId": "REQUEST_ID",
    "digest": "REQUEST_DIGEST", "action": "create",
    "keyId": "NEW_KEY_ID", "createdAt": 1790000000
  },
  "applied": true,
  "secretAvailable": true,
  "secret": "ONE_TIME_SECRET"
}
```

`applied` means the current listener acknowledged the persisted configuration, not that a transfer occurred. The secret is consumed only after this acknowledgement and a final caller-validity check. It is neither stored in application settings nor included in request audit records. The native explorer displays it in a separate masked modal with explicit copy; closing clears the page's secret controller. The generic result pane contains only the receipt.

### Pause, resume and revoke

```json
{"version":"KEYS_VERSION","requestId":"REQUEST_ID","action":"pause"}
```

Send this JSON to `/keys/KEY_ID/manage`. `action` is `pause`, `resume` or `revoke`. Pause preserves the verifier but disables authentication; resume enables the same key; revoke removes that key. Published pause/revoke takes effect through the existing runtime revocation mechanism. The current caller cannot target itself.

## Replay and unknown outcomes

The key mutation and its receipt are persisted in one settings value. Every replay must retain **the original request ID and the entire original body, including the old version**, plus the original target key ID. A new version with the old request ID is a different body and returns `409 request_id_conflict`.

- Same caller, request ID and body: return the original receipt with `secretAvailable:false`; do not create or mutate another key.
- Same ID but changed body: `409 request_id_conflict`.
- A new request with a stale version: `409 keys_changed`.
- Persisted configuration not yet acknowledged: return the receipt with `applied:false`, no secret. Query its receipt or replay the same request to reconcile publication.
- HTTP timeout, interruption or storage acknowledgement loss: query `/keys/requests/REQUEST_ID` using the original caller. A committed-but-unacknowledged store write is read back before accepting further operations; unreadable state is blocked rather than guessed.
- A lost first secret is not recoverable. Use the receipt's key ID to revoke that key, then create a replacement with a new request ID and newly read version.

Receipts survive app restart and contain no plaintext secret or verifier. They are limited to 256 entries and **are not silently evicted**: after capacity is reached, new remote mutations return `409 receipt_capacity`, while receipt reads, metadata reads and local key administration remain available. This batch does not provide receipt pruning. An explicit complete API configuration reset also removes keys and receipts; it is not an automatic retention mechanism.

## Private response handling example

`BASE` includes the prefix, and `LEGNASEND_API_TOKEN` is supplied by the caller's secret store. Save a creation response privately rather than printing it:

```python
import json, os, urllib.request
base = os.environ['LEGNASEND_API_BASE']
headers = {'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN'],
           'Content-Type': 'application/json'}
body = {'version': 'KEYS_VERSION', 'requestId': 'REQUEST_ID', 'name': 'Reader',
        'grant': {'scopes': ['service.read'], 'workspaces': ['*']}, 'expiresAt': None}
request = urllib.request.Request(base + '/keys/create',
    data=json.dumps(body).encode(), headers=headers, method='POST')
with urllib.request.urlopen(request, timeout=40) as response:
    payload = response.read(262144)
fd = os.open('key-response.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as target:
    target.write(payload)
```

Use the listener's trusted certificate configuration when HTTPS is enabled. A creation response is never a URL parameter, a log field or a shared example token.

## Stable error codes

| Code | Meaning |
|---|---|
| `global_key_required`, `insufficient_scope` | Missing dedicated scope or global authorization |
| `grant_escalation` | Grant or lifetime would exceed caller authority |
| `self_management_forbidden` | The target is the current caller |
| `keys_changed` | Re-read metadata before a new intent |
| `request_id_conflict` | Preserve the original body for reconciliation |
| `receipt_not_found` | No durable receipt is visible to this caller |
| `receipt_capacity` | Receipt capacity reached; no old receipt was discarded |
| `key_not_found`, `key_expired` | Target is unavailable or cannot be resumed |
| `operation_expired`, `keys_authority_changed` | Claim or caller validity changed |
| `key_operation_failed`, `keys_unavailable` | Persistence/runtime availability needs reconciliation |

## Validation boundary

Dedicated tests exercise real Rust HTTP authorization and response allowlists, serialized persistence and restart replay, committed writes with lost acknowledgements, and the actual native HTTP → child isolate → app owner → private file → runtime acknowledgement path. UI tests cover English and three Chinese locale variants. These host checks do not certify Android/iOS secure-store, background or physical-device behavior.

Batch checks: 40/40 Flutter provider/model/widget tests (including 10 key-persistence and four localized modal tests); native full-chain key lifecycle 1/1. Flutter analyze reported no issues. Rust authorization tests are recorded separately in the evidence document.
