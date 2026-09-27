# LegnaSend integration API

[简体中文](INTEGRATION_API_ZH.md)

## Current implementation


The prefix is `/api/legnasend/v1/integration`, on the existing listener’s **actual** port. It is separate from the browser-cookie API at `/api/legnasend/v1/workspaces` and the original `/api/localsend/v2` protocol. API settings and budgets do not rate-limit either of those existing namespaces. Original handshakes, certificate identity checks and file bytes remain unchanged.

API access defaults to disabled and authentication defaults to required. Enabling it does **not** change TLS client-certificate policy. A TLS listener without browser-sharing mode still requires a client certificate. Existing browser-sharing mode retains its previous behavior. Configure trust for the device certificate; a Bearer key neither supplies TLS trust nor turns HTTP into HTTPS.

New settings default to HTTP with HTTPS transport off; an explicitly saved choice is preserved. Native receiving, browser shares, workspaces and integration APIs share the actual listener protocol. A confirmed transport change updates that listener and its preference together. Peer protocol tags describe the remote device, not the local switch.

The API tab bundles this guide, the directory contract, the receive-retention guide and complete OpenAPI snapshots for offline reading. Choose English or Simplified Chinese explicitly; Traditional Chinese regions show the manual language as Simplified Chinese. Four localized OpenAPI snapshots remain available. Snapshots are not the live policy; query `/capabilities` and `/openapi.json` for the current service.

## Native management

1. Open **API** in the desktop sidebar or mobile navigation. If the receiving listener is off, use **Start receiving service**; API settings never start a second hidden port.
2. Enable the API and retain **Require an API key** unless intentionally opening the separate anonymous policy. Disabling API responses does not stop native transfers or browser workspaces.
3. Generate a named key. Select action permissions and specific workspaces, or explicitly grant all current/future workspaces; choose 30 days, 90 days or no expiry. Assigned hidden/password workspaces are included in an explicit key grant independently of browser passwords.
4. Copy the one-time plaintext from the in-page modal. Copy is explicit and failures keep the text available; closing does not copy automatically. Only the verifier and metadata are persisted. A lost key must be revoked and replaced; it cannot be recovered from settings or diagnostics.
5. Edit all three budgets and the canonical cross-origin allowlist in one scrollable dialog. Anonymous permissions/workspaces are configured separately, with no anonymous audit or upload access. Zero disables that configured limit; independent hard resource caps still apply. Individual keys may override the shared key budget. The core validates candidates even while the listener is off, before preferences are written.
6. Use the interface-tagged actual address. Local/tunnel labels do not prove VPN bypass. Status is an acknowledged snapshot with an observation time; **Refresh status** reads the service without rewriting an unchanged policy.
7. Saved changes and confirmed runtime state remain separate. A failed disable/revoke may leave the previous policy active; the page retains that warning and offers retry. Listener changes discard late acknowledgements; reconnect reads the live revision before publishing. Neither navigating away nor renaming a key restarts transfers.
8. Unsupported/corrupt settings remain untouched until retry or confirmed reset. Reset removes all API keys and restores disabled defaults, without deleting workspace/source files.


## Implemented operations

All paths below are relative to the prefix. IDs, field names and error codes do not change with language.

| Method | Path | Required scope | Parameters |
|---|---|---|---|
| GET | `/status` | `service.read` | None |
| GET | `/capabilities` | `service.read` | None |
| GET | `/workspaces` | `workspaces.read` | None |
| GET | `/workspaces/{workspaceId}` | `workspaces.read` | Workspace UUID |
| GET | `/workspaces/{workspaceId}/files` | `files.read` | Required `generation`; optional `path`, `cursor` |
| GET, HEAD | `/workspaces/{workspaceId}/files/{fileId}/content` | `files.read` | Required `generation`; optional `preview`, `version`; `Range`, `If-Match` headers |
| POST | `/workspaces/{workspaceId}/upload` | `files.upload` (key only) | Required `generation`, `path`, exact Content-Length and raw body; optional `directory=true` |
| GET | `/managed-workspaces` | `workspaces.manage` (key only) | Includes closed scoped entries |
| POST | `/workspaces/{workspaceId}/manage` | `workspaces.manage` (key only) | Required `generation`, `action`; update fields in query; configure/password use JSON bodies |
| GET | `/approved-workspace-sources` | `workspaces.manage`, workspace `*` | Locally approved source descriptors, no paths |
| POST | `/managed-workspaces/create` | `workspaces.manage`, workspace `*` | JSON `sourceId`, `name`, `slug`; optional `visible`, `allowUpload` |
| GET | `/requests` | `requests.read` | `after` (default 0), `limit` (1–100, default 50) |
| GET | `/devices` | `devices.read` | None |
| GET | `/devices/{deviceId}` | `devices.read` | Confirmed device UUID |
| POST | `/devices/scan` | `devices.scan` | Empty body |
| GET | `/send-selection` | `transfers.read` | None |
| POST | `/transfers/send` | `transfers.send` | JSON: deviceId, selectionVersion, requestId; optional channelId |
| GET | `/transfers` | `transfers.read` | None |
| GET | `/transfers/{transferId}` | `transfers.read` | Owned task UUID |
| POST | `/transfers/{transferId}/cancel` | `transfers.control` | Empty body |
| POST | `/transfers/{transferId}/retry` | `transfers.control + transfers.send` | JSON: requestId |
| POST | `/transfers/{transferId}/remove` | `transfers.control` | Empty body |
| GET | `/openapi.json` | `service.read` | `lang`: `en`, `zh-CN`, `zh-TW`, `zh-HK`; default `en` |

The capability list names fifteen GET operations and eight POST operations; HEAD is also described in OpenAPI. OPTIONS is a policy-checked CORS preflight, not an extra business capability. Unsupported methods return 405. Unknown, duplicate or oversized query parameters return 400; never send credentials in URLs.

Workspace descriptors exclude local filesystem roots. Explicit key grants filter the workspace list and resource access. Read operations hide unassigned, closed or missing workspaces with 404; upload scope violations return 403 and missing/closed targets return 404. `generation` comes from the current descriptor; a stale value returns 409. File IDs are opaque URL-safe identifiers from the list, not arbitrary native filesystem paths. `path` is a workspace-relative directory; use the [directory contract](DIRECTORY_API.md) for cursor/path semantics.

Pages return at most 100 entries while scanning at most 512 candidates. Continue a non-null cursor even if that page has no visible entries. Cursors expire after 120 seconds. Root confinement, descendant-symlink rejection and managed `.ls` exclusion are reused. A source change requires a new descriptor/list, not blind continuation with old IDs and versions.

HEAD describes the original file; GET supports one byte range, including suffix ranges. Obtain ETag first and supply `If-Match` for subsequent reads. The ETag is a metadata/version validator, **not a full-file cryptographic digest**. `preview=1` permits the existing allowlisted media/raster MIME types; downloads retain original bytes. `version` provides the existing encoded version pin for native media requests that cannot attach `If-Match`. See the directory reference for those details.

## Local host setup and key lifecycle

The application-only APIs are:

```rust
use localsend::http::server::integration::{ApiConfig, Scope, WorkspaceGrant, create_key};

let created = create_key(
    "Automation".into(),
    WorkspaceGrant {
        scopes: vec![Scope::Service, Scope::Workspaces, Scope::Files],
        workspaces: vec![workspace_id], // A specific workspace UUID; ["*"] grants all.
    },
    None, // Optional future Unix expiry in seconds.
)?;
let config = ApiConfig {
    revision: 1, // Must increase on this running server for every update.
    enabled: true,
    keys: vec![created.record],
    ..ApiConfig::default()
};
server.configure_integration_api(&serde_json::to_string(&config)?).await?;
// Deliver created.secret once through the host's local UI. Do not log/export it.
let snapshot = server.integration_api_snapshot(); // Metadata, never key verifiers.
```

`create_key` returns 32 random secret bytes encoded in an `ls1.<UUID>.<secret>` token. Stored records contain a SHA-256 verifier, name, scope/workspace grant, creation time and optional expiry. Verification uses constant-time digest comparison. Plaintext is not recoverable from snapshots; the calling host owns persistence and one-time display. This code is the embedding interface; the native settings workflow below now drives the same validated policy through the normal server isolate.

A key is reusable until revoked or expired; “one-time display” does not mean a one-request token. Remove its record and apply a higher revision to revoke it. Changing its grant/verifier/expiry cancels its old responses; a cosmetic rename preserves its quota and responses. Other keys and native transfers stay active. Disabling the integration API cancels all its producers. Changing the CORS policy also cancels previously admitted integration streams. Already-produced transport bytes cannot be retracted.

### Pause, resume and individual budgets

The local API page can pause/resume a key without exposing or regenerating its secret. Persisted key metadata has `enabled` (default `true` for older records) and `limits` (default `null`, meaning inherit). A paused valid key returns **403 `key_paused`** and never falls back to anonymous. Pausing cancels its old active producers; resuming permits new requests with the same token but does not revive interrupted bodies. Already claimed host mutations still follow the uncertain-result rules below.

Renaming or changing only per-key budgets preserves existing responses and usage counters. Pause/resume, scope or expiry edits with the same verifier also preserve fixed-window usage rather than granting a fresh burst. A null override restores the shared key budget. These are local persisted policy controls, not new remote key-administration endpoints.

Configuration is validated before replacement: at most 512 KiB JSON, 128 keys, 256 unique workspace IDs per grant, and 16 canonical HTTP(S) origins. A wildcard must be the only workspace entry. Unknown fields, duplicate key IDs, invalid values and stale revisions fail without partial application. Configuration errors do not echo supplied secrets.

## Anonymous policy and CORS

With `authRequired=false`, the separately configured anonymous grant applies **only to visible, unprotected workspaces**. Explicit keys may access their assigned hidden/password-protected workspaces; these are deliberate key grants independent of browser unlock cookies. Anonymous users never obtain `requests.read`, `files.upload` or `workspaces.manage`. A supplied invalid, expired or revoked token returns 401 rather than falling back to anonymous access.

Send `Authorization: Bearer TOKEN`. Cookie sessions are not API credentials. Same-origin requests and explicitly configured canonical origins are accepted; cross-origin requests need a valid preflight. There is no wildcard reflection and no credentialed-cookie CORS mode. Supported preflight headers are `Authorization`, `Range`, `If-Match`, `Accept`, `Content-Type`. Preflights need no Bearer token but consume anonymous/global budgets. CLI requests without Origin are permitted subject to API authentication and rates. CORS is not a firewall or a VPN route selector.

## Rate and concurrency semantics

| Budget | Default requests/second | Default requests/minute | Default active responses |
|---|---:|---:|---:|
| Global | 30 | 600 | 16 |
| Each key | 10 | 300 | 4 |
| Each anonymous peer | 5 | 60 | 2 |

Both one-second and 60-second **fixed windows** apply, anchored to monotonic service start. This is not a rolling window: adjacent windows can allow a boundary burst. Global and caller admission are atomic. Allowed values are 0–1,000 per second, 0–60,000 per minute and 0–64 concurrent responses. **Zero means unlimited for that configured dimension**, not an unlimited service: an independent global hard cap of 64 active responses remains, returning `429` with `server.concurrent`. A key with `limits:null` inherits `keyLimits`; a non-null `{perSecond,perMinute,concurrent}` replaces all three key limits. Global limits still constrain every key. Lowering a limit applies to subsequent admissions, without resetting usage or terminating already admitted responses.

An admitted request counts once, including an eventual 400/401/403. Each range and preflight is a request; a response is not counted per chunk. Already-rejected 429 requests do not spend another request credit. Anonymous identity uses the actual socket peer, never `X-Forwarded-For`. At most 256 recent/active anonymous actors are retained; capacity exhaustion returns 429 rather than resetting old budgets.

429 responses include `Retry-After` seconds and a stable reason such as `global.minute`, `key.concurrent` or `anonymous.capacity`. `X-LegnaSend-Remaining-Second` and `X-LegnaSend-Remaining-Minute` report the smaller remaining global/caller count when a budget was available to inspect. When both applicable limits for a dimension are zero, its remaining header is the numeric sentinel `4294967295`; with one finite limit it reports that finite remainder. These are snapshots, not reservations. Concurrency describes active handler/body producers, not TCP connections or client-confirmed delivery. A separate cancellation watcher releases a stalled producer after key revocation/expiry or source closure even when the consumer is not reading. There is no bandwidth limiter in this stage.

## Errors and request records

```json
{"error":{"code":"rate_limited","requestId":"REQUEST_UUID","reason":"key.minute"}}
```

Typical errors: `api_disabled`/`not_found` (404), `unauthorized`/`revoked`/`expired` (401), `insufficient_scope`/`origin_denied` (403), `invalid_query` (400), `method_not_allowed` (405), `source_changed` (409/412), `source_gone` (410), `range_unsatisfiable` (416), `rate_limited`/`storage_busy` (429). A file response may already have sent headers when it is interrupted; treat truncation as a failed transfer, revalidate the source, and retry only authorized missing ranges. A HEAD error has no body. Byte-range 416 responses retain the existing `Content-Range` behavior.

`/requests` holds only the latest 200 completed/rejected records. `instanceId` identifies the server lifetime; restart resets the sequence/history. Use `after`, `next`, `oldest` and `latest` to detect gaps and avoid assuming a complete audit trail. The current request appears only after completion. Records contain operation ID, method category, key ID or null, status, outcome, stable error/reason, elapsed time and produced bytes. No raw URI/query, authorization header, key/verifier, local path, filename or content is stored. Byte counts describe data produced by the response body, not remote receipt acknowledgements; rejected/HEAD bodies may record zero.

### Redacted JSON/CSV export

The API explorer offers JSON and CSV export through the user's save flow, using a credential with `requests.read`. It requests the actual listener's bounded history, captures the first page's `instanceId` and `latest` cutoff, and reads at most three pages / 200 records rather than chasing requests generated by the export itself. A listener change fails the capture; detected gaps or eviction mark `incomplete`. This is a bounded history snapshot, not a durable audit archive.

Only these allowlisted fields are exported: `sequence`, `timestamp`, `requestId`, `operation`, `method`, `principal`, `status`, `outcome`, `error`, `reason`, `bytes`, `elapsedMs`. JSON adds `format: "legnasend-api-history"`, `version: 1`, `instanceId`, `throughSequence`, `incomplete` and `entries`; CSV uses fixed headers, UTF-8 BOM and an `incomplete` column. Validation rejects malformed identifiers/codes/numbers; unknown response fields are not copied. Neither format contains tokens, verifiers, URLs, native paths, filenames, content, source locators or passwords. Export does not extend the service's 200-record retention.

## Calling examples

Set the actual address, trust material and generated secret in your execution environment. Do not put a real key into shared command history or URLs. Examples use placeholders.

### cURL

```sh
BASE='http://HOST:PORT/api/legnasend/v1/integration'
TOKEN='TOKEN'
curl -H "Authorization: Bearer $TOKEN" "$BASE/status"
curl -H "Authorization: Bearer $TOKEN" "$BASE/workspaces"
curl -G -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=RELATIVE_DIRECTORY' \
  "$BASE/workspaces/WORKSPACE_UUID/files"
URL="$BASE/workspaces/WORKSPACE_UUID/files/FILE_ID/content?generation=GENERATION"
curl -I -H "Authorization: Bearer $TOKEN" "$URL"
curl -H "Authorization: Bearer $TOKEN" \
  -H 'If-Match: "ETAG_FROM_HEAD"' -H 'Range: bytes=0-65535' "$URL" -o PART.bin
```

For a listener requiring client certificates, additionally pass the paired `--cert CLIENT_CERT.pem --key CLIENT_KEY.pem`. Use the actual scheme; HTTP has no transport encryption.

### JavaScript: incremental listing

```javascript
async function listFiles(base, token, workspaceId, generation, directory = "") {
  let cursor = null;
  do {
    const query = new URLSearchParams({ generation: String(generation), path: directory });
    if (cursor) query.set("cursor", cursor);
    const response = await fetch(`${base}/workspaces/${encodeURIComponent(workspaceId)}/files?${query}`, {
      headers: { Authorization: `Bearer ${token}` },
      credentials: "omit",
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}; retry=${response.headers.get("Retry-After")}`);
    const page = await response.json();
    consumePage(page.entries); // Application-owned bounded processing, not an ever-growing DOM list.
    cursor = page.cursor;
  } while (cursor);
}
```

A browser needs certificate trust and, when cross-origin, an allowed Origin; desktop HTTP localhost tests do not establish those conditions on a phone.

### Python: stream original bytes

```python
import os
import urllib.request
import ssl

base = "http://HOST:PORT/api/legnasend/v1/integration"
url = base + "/workspaces/WORKSPACE_UUID/files/FILE_ID/content?generation=GENERATION"
headers = {"Authorization": "Bearer " + os.environ["LEGNASEND_API_TOKEN"]}
context = ssl.create_default_context(cafile="DEVICE_CA.pem") if base.startswith("https://") else None
# context.load_cert_chain("CLIENT_CERT.pem", "CLIENT_KEY.pem")  # If the listener requires mTLS.
with urllib.request.urlopen(urllib.request.Request(url, headers=headers, method="HEAD"), context=context) as head:
    headers["If-Match"] = head.headers["ETag"]
    expected = int(head.headers["Content-Length"])
written = 0
with urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=context) as response:
    with open("OUTPUT.bin", "xb") as target:
        while chunk := response.read(65536):
            target.write(chunk)
            written += len(chunk)
if written != expected:
    raise IOError("Incomplete response; revalidate before continuing")
```

This minimal example writes a new output file; it is not a `.ls` task manager or an automatic retry implementation. Integrations should handle their own interrupted output lifecycle and never overwrite an existing file silently.

## Contract and validation

The service generates [OpenAPI 3.1.0](https://spec.openapis.org/oas/v3.1.0) from the operation table. Exported snapshots: [English](integration-openapi-en.json), [Simplified Chinese](integration-openapi-zh-CN.json), [Traditional Chinese](integration-openapi-zh-TW.json), [Hong Kong Chinese](integration-openapi-zh-HK.json). Those checked fixtures describe authentication-required mode; a live document adds anonymous alternatives only for the currently allowed anonymous scopes. 429 follows [RFC 6585](https://www.rfc-editor.org/rfc/rfc6585.html#section-4); custom remaining-count headers use the semantics above.

The real-HTTP contract script validates all four documents, successful/error response schemas, original-byte hash, HEAD/Range, anonymous filtering, revocation and namespace independence. Core tests additionally cover atomic concurrency, TLS policy, stale configurations and stalled streams. Linux/Windows CI is configured but not claimed as run; full control groups and physical mobile acceptance remain open.

## Recommended integration and recovery sequence

1. Enable the API in the app, grant the required actions/workspaces, create a key and copy the actual address. Read credentials from environment or credential storage rather than embedding them in published pages.
2. Read `/status` and check `enabled`, `authRequired`, `port`, `https` and `scopes`. Read `/capabilities` and only call supported operations.
3. Read `/workspaces`, then use its `id` and `generation` for paginated files. URL-encode relative paths and cursors, including spaces, Unicode and ampersands. Descend into directory entries; use file IDs for content routes.
4. HEAD obtains length and the complete ETag. Send `If-Match` with single-range GET requests. Validate 206 Content-Range and byte counts; do not append a full 200 response to partial output. Revalidate length after 416 and handle empty files independently.
5. Retain verified complete chunks after network failure. Re-read workspace generation and HEAD before resuming. Stop stale tasks on 409/410/412 and relist; never join new source bytes to old cache.
6. Stop automatic retries on 401 and replace credentials. Inspect scopes/origin on 403; check API enablement/grants on 404 without inferring hidden resources. Correct 400/405 calls. Honor Retry-After on 429 using bounded backoff and concurrency.
7. Authorized clients poll `/requests?after=...&limit=...`, detect instance changes and ring-history gaps. Producer bytes are not receiver disk acknowledgements; verify and commit output independently.

When HTTPS is explicitly enabled, use the actual https address and add `--cacert DEVICE_CA.pem` to cURL examples. The original client-certificate requirement still applies outside browser sharing mode. API Bearer credentials do not replace browser cookies/PINs. Explicit key-authorized uploads are described below; existing-workspace management is also available below; other remote controls remain planned. Opening documentation neither enables the API nor generates keys or sends test requests.


## In-app endpoint explorer and request console

Open **API → API explorer**. The bundled English/Simplified/Traditional Chinese contract provides categories, path/name search, parameter schemas, response/error schemas and cURL/JavaScript/Python examples for the implemented GET operations, content HEAD and confirmed upload/workspace-management POST operations. Other app languages show an explicit English fallback. Opening the page does not send a request.

1. Enable and configure the API separately. Paste a key into the obscured credential field, or leave it empty to test your explicitly configured anonymous policy. The console neither creates keys nor bypasses scopes.
2. Select an operation. Fill required path/query parameters; numeric boundaries and enumerations are checked before sending. Use **Workspaces**, then **Files**, to obtain actual IDs and generation. **Reset** restores parameter defaults without changing server settings.
3. Choose **Execute request**. The native executor connects only to the current listener at `127.0.0.1` and its actual port/protocol, ignoring application HTTP proxies. HTTPS pins this listener's certificate and presents the existing local client certificate. It does not weaken remote certificate checks. This proves the local service path, not LAN/VPN reachability or browser CORS.
4. Inspect the real HTTP status, elapsed time, byte count, selected response headers and response body. 401/403/429 are actual server responses, not console-generated successes. Use the **Request history** operation with `after` and `limit` for the bounded, redacted service records.
5. Content GET defaults to `Range: bytes=0-4095`; change Range/If-Match explicitly if needed. Only a 4 KiB hex sample is displayed, never a full file download. Other bodies are capped at 256 KiB with a truncation marker. HEAD displays headers without content. Use a proper API client to process complete files or larger contracts.

Only one console request can run per listener, with a 12-second outer deadline for reads and the size-aware upload budget described below; there are no automatic retries. Closing the page drops its credential/controller state and ignores late results; stopping the listener cancels the request. The key is not persisted or inserted into copied examples, which use `TOKEN`/environment placeholders. Explicitly copied responses contain service data, so handle them according to your sharing policy. The service still enforces all normal budgets and records.

Generated examples use this device's loopback address. For another device, replace the host with an actual interface address from API management. HTTPS examples need the device CA and, when the listener requires mutual TLS, a separately provisioned client certificate/key; browser code also follows the explicit CORS allowlist. Confirmed file uploads are available as described below; workspace creation/configuration/password operations are described below; owned send-task controls are also available; unrelated native task/cache control and remote key management remain planned.

## Keyed file and directory uploads

Grant **files.upload** explicitly to a key and select its permitted workspaces. Neither existing read scopes, anonymous access (even with authentication disabled), browser cookies nor the browser `allowUpload` switch grant API writes. A scoped key may upload to a hidden/password-protected workspace assigned to it, even if browsers are read-only. The workspace must still be published and its generation current. Anonymous configuration rejects this write scope; invalid supplied credentials never fall back to anonymous.

`POST /api/legnasend/v1/integration/workspaces/{workspaceId}/upload?generation=N&path=RELATIVE_PATH`

- Headers: `Authorization: Bearer TOKEN`, `Content-Type: application/octet-stream`, exact `Content-Length`; raw original file body. No browser `X-LegnaSend-Upload` marker or password cookie is needed.
- Use `directory=true` with an explicit zero-length body for an empty directory. Parent directories are created as needed. Existing final names return 409; there is no overwrite, append, remote path deletion or partial upload resume.
- Successful response is **201** JSON with `path`, `size`, `sha256` and `directory`. Publication follows explicit EOF and verified length. SHA-256 describes the received data; it does not replace a caller's source hash comparison.
- Paths remain confined to the workspace; no absolute path, `..`, descendant symlink, internal cache name or overwritten destination is accepted. Root/generation changes and source closure stop unfinished writes.
- Existing global/key second/minute/concurrency budgets apply. The shared writer additionally allows two active writes per workspace and eight globally, with bounded 64 KiB chunks. API budget ownership stays alive until detached worker cleanup finishes, not merely until its request handler disappears.
- Key revocation, expiry and API disabling are checked again inside the publication gate. Revocation and commit are serialized; after a revocation acknowledgement, the old writer cannot later commit. Files committed beforehand stay intact. Records continue to redact credentials, local paths, names and content; logged body byte counts retain their existing response-byte meaning.
- CORS accepts this POST only from configured origins; the management POST routes separately enforce their management grants. `OPTIONS` remains a preflight, not a write grant. Original LocalSend routes and browser quotas are unchanged.

Typical errors use the existing structured error envelope: 400 invalid arguments, 401 missing/invalid/revoked/expired key, 403 missing write/workspace permission, 404 unavailable workspace/API, 409 stale generation or existing name, 411 missing length, 415 wrong content type, 429 quota/admission limit, 500 storage failure. A receiver that rejects a large streaming body early can cause the calling transport to fail before exposing its HTTP status; do not infer completion from bytes sent.

```sh
# The source is streamed rather than encoded in JSON; curl determines its length.
curl --request POST --upload-file FILE_PATH \
  -H 'Authorization: Bearer TOKEN' -H 'Content-Type: application/octet-stream' \
  'http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload?generation=GENERATION&path=folder%2Ffile.bin'
```

```javascript
// selectedFile comes from a user file input. Browser sets Content-Length.
const response = await fetch('http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload?generation=GENERATION&path=file.bin', {
  method: 'POST', credentials: 'omit',
  headers: {Authorization: 'Bearer TOKEN', 'Content-Type': 'application/octet-stream'},
  body: selectedFile,
});
if (response.status !== 201) throw new Error(`Upload failed: ${response.status}`);
const receipt = await response.json();
```

```python
import os
import requests
with open('FILE_PATH', 'rb') as source:
    response = requests.post(
        'http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload',
        params={'generation': 'GENERATION', 'path': 'folder/file.bin'},
        headers={'Authorization': 'Bearer TOKEN', 'Content-Type': 'application/octet-stream',
                 'Content-Length': str(os.fstat(source.fileno()).st_size)},
        data=source, timeout=(10, 3600))
    response.raise_for_status()
    receipt = response.json()
```

### In-app upload testing

Select `uploadFile` in **API → Request console**, fill workspace/generation/relative path, paste a key and choose a file (or select empty directory). An in-page confirmation shows the intended destination before writing. Examples use placeholders, never the pasted key or the selected local source path. Requests use the actual loopback listener with the existing fixed-certificate TLS/client identity, not an arbitrary URL or proxy.

The picker passes metadata only. Android content URIs are opened in the worker and transfer one owned read descriptor to Rust; provider URI/descriptor values never enter HTTP or request history. Late opens after server replacement close before execution. Ordinary sources must be regular files; streaming descriptors need a known size. Each console has one active operation, a bounded response preview and a size-aware upload budget `min(21600, 60 + ceil(bytes/1048576))` seconds; reads retain the 12-second console deadline. Closing the page does not falsely report cancellation or success of a running request. A stalled platform provider read may outlive network cancellation until its underlying read returns; physical-provider behavior remains an acceptance item.

Device discovery and owned send-task controls are available in the next section; unrelated native task/cache controls and remote key/settings management remain planned. Registered upload-partial crash cleanup is described in the [directory contract](DIRECTORY_API.md#registered-upload-partial-cleanup); external Android/Apple workspace-root adapters remain separate acceptance work.

## Persistent workspace management

Use an explicit **workspaces.manage** key and a specific workspace grant (or deliberately grant `*`). Neither old read/upload grants nor anonymous access gain this authority. Management includes closed and invalid catalog entries, unlike the ordinary published-workspace list. Native source paths, platform grant references and password verifiers are excluded. The host must be running with its management event handler; a core-only listener returns `503 host_unavailable` rather than pretending to persist settings.

| Method | Path | Inputs |
| --- | --- | --- |
| GET | `/managed-workspaces` | No query; returns `{workspaces:[...]}` restricted to the key's workspace grant |
| POST | `/workspaces/{workspaceId}/manage` | Required `generation` and `action`; empty body except configure/password JSON |
| GET | `/approved-workspace-sources` | No query; wildcard management grant; returns `{sources:[{id,name,kind}]}` |
| POST | `/managed-workspaces/create` | Wildcard management grant; JSON creation body described below |

Actions:
- `update`: one or more of `name`, `visible=true|false`, `allowUpload=true|false`; omitted flags stay unchanged. A blank name or empty update is rejected.
- `enable`: recheck the existing local source before opening it.
- `disable`: close this workspace without stopping the listener or other workspaces.
- `validate`: recheck the source; never reopen a manually closed workspace. An invalid source is disabled and saved, with `422 workspace_invalid` after publication.
- `destroy`: remove this workspace's sharing configuration, **never delete its source directory/files**.

`generation` is a compare-and-swap precondition against the durable catalog, checked inside the same serialized queue as native UI edits. A stale value returns `409 stale_generation` without writing. Metadata changes advance generation. Get a fresh descriptor before a later change; do not blindly retry an old operation. Source and route changes use the separate `configure` action and require the workspace to be closed; password changes use the separate `password` action. Arbitrary native paths, platform grant references and caller-supplied password hashes are never accepted.

The descriptor contains `id`, `name`, `slug`, `generation`, `enabled`, `visible`, `allowUpload`, `passwordProtected` and nullable `invalidReason`. Here `enabled` is the saved intention, not independent proof of a live route. A successful mutation waits for persistence **and** the service publication/withdrawal acknowledgement. Create/update/configure/password/enable/disable/validate responses contain `{workspace:...}`; destruction returns `{id,destroyed:true}`. A saved change whose service synchronization fails returns `503 config_saved_sync_pending` with a safe receipt; it is not rolled back or reported as fully applied. Query catalog and published-workspace state and use the client's synchronization retry before further changes.

### Approved sources, creation, route changes and passwords

A user first opens **Workspaces → Approved API sources** locally, chooses a directory and names its approval. The persisted approval binds a random `sourceId` to that exact local source; remote descriptors expose only `id`, `name` and `kind`, never its path or platform grant. Only a `workspaces.manage` key with workspace grant `["*"]` may list approvals or create workspaces; a specific-workspace key gets `403 wildcard_management_required`. Approval/revocation itself is local-only. Revocation prevents later creation or reassignment through that source ID (`404 source_not_approved`); it does **not** close or delete workspaces already using the source. Disable/destroy those workspaces separately when withdrawing existing access.

`POST /managed-workspaces/create` accepts an `application/json` object:

```json
{"sourceId":"SOURCE_UUID","name":"Documents","slug":"documents","visible":true,"allowUpload":false}
```

`sourceId`, `name` and `slug` are required; omitted flags default to visible/read-only. Success is **200** `{workspace:...}`, with a newly generated ID, `generation:1`, `enabled:false` and no password. Creation does not open/probe the source. Set a password if needed, then explicitly enable with its latest generation; enable probes the actual source. Slugs normalize to lowercase, follow `[a-z][a-z0-9-]{0,47}`, cannot end in `-`, collide with another route or use reserved service names. No retry token/idempotency key is offered: after an uncertain create response, inspect the catalog before creating again.

Existing-workspace changes use `POST /workspaces/{workspaceId}/manage?generation=N&action=ACTION`:

| Action | JSON body | Condition |
| --- | --- | --- |
| `configure` | `{"sourceId":"SOURCE_UUID","slug":"new-route"}`; either or both fields | Must be closed; otherwise `409 workspace_must_be_closed`. Source ID must still be locally approved. |
| `password` | `{"password":"PASSWORD"}` **or** `{"clear":true}` | Exactly one form; 4–128 Unicode characters for a password, no control characters. Does not require closure. |

Both actions use the same serialized generation CAS and persistence/publication acknowledgement. Configuration retains closure and advances generation; enable must revalidate the changed source. Password changes persist only the salted verifier, advance generation and revoke old browser grants/streams when applied. Explicit API-key grants remain independent of browser passwords. JSON bodies are bounded to 8 KiB with a five-second read deadline; unknown fields, an empty configuration or mixing clear/password are rejected. Never put a password in the query, history or copied examples. HTTP still exposes credentials in transit; use an appropriately trusted HTTPS listener when transport protection is required.

```sh
curl -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/approved-workspace-sources"
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"sourceId":"SOURCE_UUID","name":"Documents","slug":"documents"}' \
  "$BASE/managed-workspaces/create"
# After disabling and reading the new generation:
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' --data '{"slug":"documents-new"}' \
  "$BASE/workspaces/ID/manage?generation=GENERATION&action=configure"
```

The in-app explorer exposes these operations with fields sent in JSON bodies and mutation confirmation. Password request bodies are not copied into generated calling examples. Approved-source storage does not by itself implement Android document-tree or Apple bookmark roots; actual source adapters and physical grants retain their separate acceptance requirements.

### Cancellation and uncertain results

Authorization is claimed atomically just before the host begins a queued operation. Revoked/expired keys and cancelled or timed-out unclaimed requests cannot start a mutation. Once claimed, a persistent change may finish despite a later disconnect, key revocation or listener change. The HTTP deadline is 30 seconds including queue time; after a claim, a timeout/revocation reports `outcome_unknown` (504/503), **not** “nothing changed.” Inspect current catalog state before deciding what to do next. There is no automatic mutation retry or rollback guarantee. The native console permits 35 seconds, including the server's 30-second acknowledgement window; ordinary read operations retain 12 seconds.

Core pending requests are bounded at 32, the app's active host handlers at 16, and normal API budgets still apply. Accepted pending persistence continues holding its API concurrency lease after HTTP timeout; late host acknowledgement releases it. The FRB cleanup timer discards only unclaimed closed requests, not accepted writes still in flight. Isolate result streams close and detach on terminal errors and consumer cancellation.

### Examples

The base below includes `/api/legnasend/v1/integration`. The key must have management permission for `ID`. Examples use HTTP to match the default listener; HTTPS follows the certificate requirements above.

```sh
curl --include -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/managed-workspaces"
curl --include --request POST --data-binary '' \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  "$BASE/workspaces/ID/manage?generation=GENERATION&action=update&visible=false"
```

```javascript
const url = new URL(`${base}/workspaces/${workspace.id}/manage`);
url.search = new URLSearchParams({ generation: String(workspace.generation), action: 'disable' });
const response = await fetch(url, {
  method: 'POST', headers: { Authorization: `Bearer ${token}` },
  credentials: 'omit', body: '',
});
console.log(response.status, await response.json()); // Reconcile 409/503/504; do not auto-retry.
```

```python
import json, os, urllib.request, urllib.error, urllib.parse
query = urllib.parse.urlencode({'generation': generation, 'action': 'validate'})
request = urllib.request.Request(base + '/workspaces/' + workspace_id + '/manage?' + query,
    data=b'', method='POST', headers={'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN']})
try:
    response = urllib.request.urlopen(request, timeout=35)
except urllib.error.HTTPError as error:
    response = error
with response:
    print(response.status, response.read(262144))
```



## Device discovery and owned send tasks

These ten operations are available on the same integration prefix and use the existing host event/claim bridge. They do **not** accept arbitrary filesystem paths, remote hostnames/IPs or subnet ranges. The source is the current selection in the host app’s Send tab, not an arbitrary workspace directory. Building a selection from workspace file IDs and controlling unrelated native receiving/sending sessions remain separate work.

### Permission and lifetime

All five new permissions are **key-only** and require an explicit `workspaces: ["*"]` grant because devices and the local selection are application-wide resources. Existing keys do not gain these scopes; anonymous grants reject them. The native key editor requires an explicit all-workspaces selection rather than silently broadening a restricted key. `transfers.control` alone can cancel/remove its own tasks but cannot retry: retry also requires `transfers.send`. Sending does not imply read/list permissions; grant `devices.read` and `transfers.read` when the caller needs discovery, selection metadata and progress.

Tasks are owned by the creating key UUID, not its display name. A different key receives 404 for inspection, cancellation, retry or removal. User-created queue jobs and unrelated incoming/native sessions are not API-controlled. Rename/pause/resume preserves ownership; replacing a revoked key does not inherit its tasks. Disabling or revoking API access does not silently cancel a native job already accepted by the host. The app’s normal task controls remain available.

Device/channel IDs, selection versions, tasks and idempotency receipts live in memory. A process restart loses them; refresh `/status` and device/selection state instead of assuming an old task is resumable. Listener reconfiguration within the same running app does not discard accepted queue jobs. Receiver approval and PIN interaction follow the original app flow; neither an API key nor a 202 response bypasses the receiver.

### Discovery and source selection

`GET /devices` returns `{devices, truncated, scanState}`. `scanState` is `idle`, `running` or `failed`; failures are redacted rather than exposing platform errors. The list covers at most 512 confirmed HTTP devices, at most 32 known channels each and a 200 KiB encoded-description budget. `truncated=true` reports clipping; this bounded snapshot has no cursor. `GET /devices/{deviceId}` returns `{device}`. Each device has `id`, `alias`, `deviceType` and `channels`; each channel has `id`, `host`, `port`, `https`. These are confirmed peer entry points, not a claim that the OS will bypass a VPN. Device/channel IDs may change after disappearance and rediscovery; refresh the device list after a 404. Omitted `channelId` uses the first confirmed entry at acceptance; every queued job pins the resolved channel.

`POST /devices/scan` has an empty body and returns 202 `{accepted:true,coalesced:boolean}`. It invokes the existing local smart discovery, merges in-flight calls and applies a five-second cooldown. Poll `/devices` for the resulting scan state/list. It does not scan caller-supplied addresses or change network settings.

`GET /send-selection` returns `{selectionVersion,totalCount,totalBytes,truncated,files}`. `files` contains only up to 100 bounded basename/size previews, never native paths or message contents. All selected files, including selections larger than 100 files, are sent; the preview is not a subset selector. Names are rune-safe UTF-8-bounded previews. The version tracks the current local selection object, **not a file-content digest or immutable disk snapshot**. Selection changes make a new send using the old version fail with 409 `selection_changed`; ordinary source validation/checksums still happen in the existing sender.

### Enqueue, inspect and control

`POST /transfers/send` accepts only this JSON body (maximum 8 KiB):

```json
{"deviceId":"DEVICE_UUID","selectionVersion":"SELECTION_UUID","requestId":"REQUEST_UUID","channelId":"CHANNEL_UUID"}
```

All IDs must be canonical lower-case UUID v4 strings. `channelId` is optional. A valid request returns **202** `{task,replayed:false}` after actual queue admission, not after delivery. No private aggregate transport or archive replacement is introduced. Source files and their original v2 metadata/bytes pass through the existing size-aware scheduler and pinned client. A disappeared explicit endpoint fails rather than switching to another route.

`GET /transfers` returns `{tasks}` for the calling key. `GET /transfers/{transferId}` returns `{task}`. A task contains `id`, `deviceId`, `status`, `fileCount`, `totalBytes`, `transferredBytes`, `bytesPerSecond`, and optional `result`, `retryOf`, `removed`. Status is `queued`, `running`, `succeeded`, `failed` or `canceled`. Progress comes from the actual queue/session and shared rate sampler; 0 speed also covers a not-yet-available sample and terminal tasks. Raw local error strings, file paths, tokens and file contents are absent. A transport receipt is not remote user confirmation beyond the original protocol’s success response.

- **Cancel:** empty POST to `/transfers/{id}/cancel`; 200 `{task}`. Cancel queued work or stop the real active session. A canceled task can still be draining; its device slot remains reserved until cleanup finishes.
- **Retry:** POST `/transfers/{id}/retry` with `{"requestId":"NEW_REQUEST_UUID"}`. Requires a terminal owned task and both control/send permissions; 202 `{task,replayed:false}` creates a new attempt retaining files and the explicit peer channel. This is **whole-file retry**, not byte-range resume. All original task files are resent, including previously completed files. The original record remains available. A successful terminal task may also be intentionally sent again.
- **Remove:** empty POST to `/transfers/{id}/remove`; 200 `{removed:true,id}` only after actual queue-history removal. Active tasks return 409 `transfer_not_terminal`; a canceled-but-draining job returns 409 `transfer_busy`. Files are never deleted.

### Idempotency and outcome uncertainty

Choose a fresh `requestId` for a new send/retry intent and retain it **before** issuing the request. Repeating the same key/request ID and identical semantic body returns the original task with `replayed:true`, including a redacted `removed:true` receipt after history removal. It never re-enqueues. Reusing that ID for a different send/retry payload returns 409 `idempotency_conflict`.

The host retains at most 512 accepted receipts across all keys for its current process lifetime and never silently evicts accepted receipts to make a repeated request look new. The existing queue allows at most 128 nonterminal jobs. Either capacity limit returns 429 `transfer_queue_full`. Removing history does not erase replay protection; an app restart resets runtime receipts/IDs and requires a fresh selection/discovery read. These limits count jobs, not selected files.

A timeout after host acceptance may have an unknown outcome. Retry the exact same request ID/body; do not generate a new ID just to clear a transport error. Before acceptance, ordinary authorization/version/body failures do not consume a receipt. The native explorer preserves send/retry drafts through operation changes and failures while the page remains open; its explicit **New request ID** action requires confirmation. Save IDs outside the page if closing the explorer or automating from another process.

Common errors include 403 for missing scope/wildcard/paused access; 404 `device_not_found`, `channel_not_found` or `transfer_not_found`; 409 `selection_changed`, `empty_selection`, `idempotency_conflict`, `transfer_not_terminal`, `transfer_busy`; and 429 `transfer_queue_full`. Native host availability and existing management claim/outcome errors also apply. Query parameters are not accepted by these operations; secrets stay in the Authorization header and JSON is used only on send/retry.

### Calling examples

Create UUIDs once per intent, retain them and substitute current IDs obtained above. `BASE` includes the integration prefix. The API explorer generates equivalent examples for every operation.

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/devices"
curl -H "Authorization: Bearer $TOKEN" "$BASE/send-selection"
# Save intent.json once. Reuse the same file for an uncertain-outcome retry.
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @intent.json "$BASE/transfers/send"
curl -H "Authorization: Bearer $TOKEN" "$BASE/transfers/$TASK_ID"
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Length: 0' \
  "$BASE/transfers/$TASK_ID/cancel"
```

```javascript
// Keep this body unchanged when recovering a lost response.
const body = {deviceId: DEVICE_ID, selectionVersion: SELECTION_VERSION, requestId: REQUEST_ID};
const response = await fetch(`${BASE}/transfers/send`, {
  method: 'POST', headers: {Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json'},
  credentials: 'omit', body: JSON.stringify(body)
});
const receipt = await response.json(); // Check response.status before using receipt.task.
```

```python
import json, urllib.request
body = {"deviceId": DEVICE_ID, "selectionVersion": SELECTION_VERSION, "requestId": REQUEST_ID}
request = urllib.request.Request(BASE + "/transfers/send", data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(request) as response:
    receipt = json.load(response)
# Retain request ID and task ID; poll /transfers/{taskId} for actual completion.
```


General picker/photo/mobile temporary cleanup is deferred if the current selection, any retained send-queue history (including terminal retries) or native send sessions still hold sources. Registered receive-cache cleanup remains independent. Remove unused history before requesting generic cleanup again. This is a conservative pre-start check, not a provider lease against selections created after a bulk cleanup has already started; mobile provider/background acceptance remains separate.

## Owned-cache administration and supported app settings

These four operations use the existing claimable host bridge and require **explicit key-only scopes plus `workspaces: ["*"]`**. Old keys do not acquire them. Anonymous grants reject all four permissions. Neither browser cookies nor workspace write permission authorize host administration.

| Method and suffix | Permission | Result |
|---|---|---|
| `GET /cache` | `cache.read` | Read-only, bounded inspection of registered native staging |
| `POST /cache/cleanup` | `cache.clean` | Identity/lock-checked cleanup of inactive registered staging |
| `GET /settings` | `settings.read` | Versioned allowlist of non-secret app settings |
| `POST /settings/update` | `settings.write` | Persist one supported setting after a version check |

Empty-body operations reject JSON payloads and unknown query fields. No endpoint accepts a local path, arbitrary glob, cache filename or caller-specified deletion target. Original LocalSend traffic is unaffected.

### Cache response

Both cache operations return `examined`, `removedFiles`, `removedRecords`, `plannedBytes`, `unlinkedBytes`, `active`, `retained`, `failed`, `budgetReached`, `interrupted`, `entries`, and `entriesTruncated`. Each of at most 128 entries contains `id` (opaque lower-case SHA-256 identity), `sourceKind` (`nativeReceive`, `directoryUpload`, `unknown`), `disposition` (`candidate`, `removed`, `retired`, `retained`, `active`, `failed`), stable `reason`, `plannedBytes`, and `unlinkedBytes`. Names, paths, SAF URIs, credentials and contents are omitted.

Inspection does not unlink data, retire registrations or rewrite the cleanup cursor. It covers registered ordinary-path staging, not arbitrary `.ls` files, picker caches, browser temporary files, or an exhaustive Android provider inventory. Cleanup also reuses existing Android provider reconciliation where available; provider-only details can remain summarized rather than appearing as ordinary-path entries. Unknown ownership, active locks and ambiguous permissions remain protected.

One API call requests one bounded batch. `budgetReached` means more scanning may remain; `entriesTruncated` means the response list omitted details, independently of scanning. Inspection and cleanup maintain independent cursors. A simultaneously running native cleanup can be joined rather than duplicated. Counts are logical file lengths and unlinks, **not measured freed disk space**. A failure after unlink but before registry retirement can report both `failed > 0` and `unlinkedBytes > 0`. An HTTP 200 reports a completed diagnostic attempt, not that every entry was deleted: inspect `failed`, `interrupted`, and per-entry disposition.

### Settings response and writes

Reads return `{ "version": "64-hex-digest", "settings": {...}, "pendingRestart": [], "receiveCacheRetention": {...} }`. The snapshot includes exactly `alias`, `theme`, `locale`, `enableAnimations`, `autoFinish`, `createChecksums`, `verifyChecksums`, and `receiveCacheRetentionDays`. `theme` is `system`, `light`, or `dark`; `locale` is an app-supported language tag or `system`. Boolean values are JSON booleans, not strings. Alias is nonempty, at most 120 UTF-16 units in the host, and contains no control characters. These operations never restart the listener automatically. Alias and receive checksum verification are saved configuration: if they differ from the running listener, `pendingRestart` lists `alias` and/or `verifyChecksums`. The existing listener and discovery identity remain unchanged until a deliberate local service restart. Theme/language/animation changes update the interface; send-checksum changes apply to subsequent sending work. API policy, receive PIN, keys, destination paths, quick acceptance, ports and TLS are deliberately not exposed by this endpoint.

Send `{ "version": "VERSION_FROM_READ", "field": "theme", "value": "dark" }`. The host serializes these operations, compares the snapshot version before and after claiming authority, and waits for the existing settings persistence method before returning the updated snapshot. A stale version returns 409 `settings_changed`; invalid fields/types/language tags return 400; storage failure returns 503 `host_operation_failed` without private exception text. The version covers settings, pending-restart state and the retention runtime snapshot and is an optimistic snapshot token, not a monotonic historical revision: changing settings back to identical values produces the same token. A local UI edit after the request is claimed is a later concurrent intent, not locked out remotely.

`receiveCacheRetentionDays` is a strict JSON integer −1…3650: −1 keeps manually, 0 allows automatic cleanup, and positive values retain registered native crash leftovers for that many days. The required top-level `receiveCacheRetention` reports `effectiveDays` (nullable integer), `automaticCleanupPaused`, `busy`, and `error` (`null`, `invalid`, `save`, `apply`, `restore`). Saved and effective policy may differ. Busy updates return 409 `settings_busy`; failed synchronization returns 503 `host_operation_failed`. Updating does not perform cleanup or grant a retention bypass. API cache cleanup still respects the policy. See the [complete retention developer guide](API_RECEIVE_RETENTION.md) for scope, typed cURL/JavaScript/Python examples, boolean/string rejection and recovery decisions.

After a claimed mutation times out or loses its connection, inspect current state. Do not automatically retry it. The existing 30-second host deadline and `outcome_unknown` behavior apply. The native API explorer supplies cURL, JavaScript and Python examples with a supported body editor and in-page confirmation before cleanup or settings writes.

```sh
curl -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  http://HOST:PORT/api/legnasend/v1/integration/settings
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"version":"VERSION_FROM_READ","field":"theme","value":"dark"}' \
  http://HOST:PORT/api/legnasend/v1/integration/settings/update
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" --data '' \
  http://HOST:PORT/api/legnasend/v1/integration/cache/cleanup
```

Remote API-key lifecycle administration and arbitrary listener/security-setting mutations are not implemented by these endpoints; local key management remains available in the app. API permissions are not silently broadened to approximate missing controls.

### Current-directory name filtering

`GET /workspaces/{workspaceId}/files` accepts optional `filter`: a literal case-insensitive substring of each immediate file/folder base name. It is not recursive, not a regular expression and not text-content search. Maximum 256 Unicode characters; control characters are rejected. The page echoes `filter`, and cursors bind its exact original value as well as workspace, generation, directory and metadata stamp. Reusing a cursor with a changed filter returns 400. Keep requesting pages while `cursor` is non-null even if `entries` is empty: each page scans at most 512 source entries and returns at most 100 matches. Filtering retains the same authentication and workspace-grant checks as ordinary listing.

## Remote key lifecycle and request-history administration

Remote key administration now requires explicit `keys.manage` and the global `*` grant. See the complete key lifecycle guide for metadata, bounded delegation, one-time secret delivery, persistent receipts, exact-body replay and error recovery. Request-history clearing uses `POST /requests/clear` with explicit `requests.manage`, captured `instanceId`, `expectedGeneration` and `throughSequence`; it retains later completions and a redacted clear marker without resetting sequence, limits or active transfers.

## Key lifecycle developer reference


中文版

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

## Global native task controls

`GET /native-tasks` requires `nativeTasks.read`; `POST /native-tasks/{taskId}/control` requires **`nativeTasks.control`**. Both require a valid explicit key with `workspaces: ["*"]`. Existing keys do not gain these permissions, and anonymous policy rejects them. Unlike `/transfers`, this interface sees native tasks created locally or by other keys. Browser response activity and browser approval cards are excluded.

The snapshot is `{epoch, tasks, truncated}`. Active tasks appear first; at most 512 currently retained tasks are returned. Each task exposes only `id`, `version`, `direction`, `phase`, `fileCount`, `totalBytes`, `transferredBytes`, `bytesPerSecond`, `actions`. No names, local paths, peer addresses or raw errors are returned. IDs and versions are opaque UUIDs; `epoch` changes when the listener generation changes. Progress increments alone do not invalidate the control version. Changes to phase, session attempt, receive destination/gallery setting or local file selection/renaming do. Terminal speed is zero. This is a live retained-task view, not an exhaustive persisted receive-history database.

Controls require exactly `{epoch, version, action}` using the snapshot's task ID. Only the actions advertised on that task are valid:

- `accept` / `reject`: pending native receive requests. Acceptance uses the current local selected file names and configured destination, never an API-supplied path. A message acknowledgement follows the native message path.
- `cancel`: an active native send or already accepted receive, independently of the opposite direction. Already published received files remain.
- `remove`: ordinary terminal task records only. Active tasks and restored send entries cannot be removed by this endpoint; the latter can own retained source staging. The operation does not delete original files.

Claim and task-version checks run immediately before dispatch. Each admitted control consumes its version before asynchronous effects: repeating the same POST returns `409 native_task_changed`. A successful `{epoch,id,action,dispatched:true}` means the host dispatched the existing native controller operation, **not** that a peer has acknowledged cancellation or completed file reception. Listener replacement, local edits and newer sessions invalidate stale controls. There is no pause/resume operation or fabricated byte-resume capability.

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/native-tasks"
curl --request POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"epoch":"EPOCH_UUID","version":"TASK_VERSION_UUID","action":"cancel"}' \
  "$BASE/native-tasks/TASK_UUID/control"
```

Use the current UUID values from the first response. On `409`, refresh before deciding again. On transport failure or `outcome_unknown`, refresh task state; never automatically resubmit a control. The app's API explorer includes all four supported documentation languages, inline body fields, an in-page confirmation showing the target and action, and no automatic retries. No original LocalSend endpoint, handshake, certificate check or file encoding changes.

## Send versioned workspace files to a discovered device

`POST /workspaces/{workspaceId}/send` additionally requires **`transfers.send`, `files.read`, and global `*`** on the same valid key. Console operation ID: `sendWorkspaceFiles`. Read `/status` for `instanceId`, the workspace descriptor for `generation`, its file list for canonical file IDs and exact quoted ETag `version` values, and `/devices` for destination IDs. Do not invent file paths or device addresses.

```json
{
  "instanceId": "CURRENT_SERVICE_UUID",
  "generation": 1,
  "deviceId": "DISCOVERED_DEVICE_UUID",
  "requestId": "NEW_INTENT_UUID",
  "files": [{"id": "FILE_ID", "version": "\"EXACT_ETAG\""}]
}
```

An optional `channelId` pins a discovered network entry. The body is limited to 64 KiB and 1–128 distinct file IDs; directory recursion, paths, URLs, overwrite controls and arbitrary IPs are not accepted. The host validates the published workspace/source versions, captures immutable local staging, and submits those files through the existing native send queue. The app's UI selection is not changed. Read permission is mandatory even when a key already has send permission.

`202 {task,replayed}` has the same progress and key-owned receipt semantics as `/transfers/send`. It means queued, not delivered. Poll `/transfers/{task.id}` for actual state/speed. Preserve the exact request ID and body after an uncertain result; a changed body under an existing ID conflicts. A different service `instanceId` yields `409 service_instance_changed` rather than silently treating an old intent as a new send. A new explicit send after restart needs a freshly inspected source and new intent. Transfer bytes continue using the original LocalSend protocol.

### Foreground workspace validation

`GET /workspaces/{workspaceId}/state?generation=1&path=sub&ids=FILE_ID,FILE_ID` requires `files.read` and a matching workspace grant. Anonymous access follows the same visible/unprotected workspace policy as file listing. The finite response contains `generation`, `path`, a directory metadata `stamp`, `entries` and `missing`; at most 64 unique canonical IDs from the requested directory are accepted, with an 8192-byte query-value limit. Each regular entry includes a quoted `version` matching its download ETag; directory versions are null. Use this version when capturing workspace sources for device sending.

Poll only visible entries on foreground/online recovery. A changed directory stamp means restart paginated listing; missing IDs leave the current view. Same-length content edits may leave the directory stamp unchanged, so compare each file version too. These are metadata validators, not content hashes, recursive filesystem snapshots, watchers or a continuous event stream. A stale workspace generation returns 409; an inaccessible workspace returns 404. Recheck versions before downloading or sending; an observation does not reserve the source.

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/workspaces/$WORKSPACE_ID/state?generation=$GENERATION&path=sub&ids=$FILE_ID"
```

The localized in-app explorer exposes this operation and generates cURL, JavaScript and Python requests. This is a bounded incremental foreground check, not an unbounded scan.

### Parameter size accounting

HTTP, the native console and the explorer enforce the same published bounds. Normal parameter values allow at most 4096 UTF-8 bytes. `getWorkspaceState.ids` allows 8192 ASCII bytes containing at most 64 comma-separated canonical IDs; this exception does not permit local paths or URLs. The `filter` field additionally permits at most 256 Unicode code points, and supported header values have a 1024-byte limit. Schema `minLength`, `maxLength`, `pattern` and enum constraints still apply.

The percent-encoded query has a separate aggregate budget: 24 KiB for workspace state and 8 KiB for other operations. The local state-console envelope allows 24 KiB, including JSON escaping; other operation envelopes retain their existing limits. An input may fit its character limit yet exceed UTF-8 or encoded-query limits. The explorer retains the entered value and reports invalid input rather than silently truncating IDs. These limits do not authorize arbitrary paths, change grants or turn a read operation into a write.


### Selecting a task-local outgoing route

A valid key with `devices.read` and wildcard `*` can read `GET /devices` → `localRoutes`. Each entry has `id`, `interfaceName`, `address`, and `binding` (`interfaceAndSource` on Apple/Linux/Windows; `androidNetwork` for Android system Network entries, otherwise `sourceOnly`). Older hosts may omit this optional list. These addresses are not exposed through anonymous status access.

Use a listed UUID as optional `localRouteId` in `POST /transfers/send` or `POST /workspaces/{workspaceId}/send`. Existing transfer scopes still apply; workspace sends also need `files.read`. Omission keeps automatic routing. Do not submit raw interface names, IPs or a `localRoute` object. Example fragment, combined with the endpoint's other required fields:

```json
{"localRouteId":"11111111-1111-4111-8111-111111111111"}
```

The task receipt echoes the selected ID. The choice is part of idempotency: changing it while reusing `requestId` returns `409 idempotency_conflict`. Retry preserves the original task's route rather than the current UI choice; it cannot override that route. Removed routes return `409 local_route_unavailable`, without unbound fallback. Network disappearance retires its observed ID; rediscovery generates a new ID. IDs expire on app restart. A completed idempotent replay still returns its original receipt, even if the route has since disappeared.

Source snapshots and queued tasks retain the local route. The native client rechecks the actual interface and binds its source before requests. This is not proof of VPN bypass: Android system Network entries capture a process/lifecycle lease and bind every new socket to its validated handle; older source-only entries keep their weaker capability. Network loss invalidates the lease, including reused handles. Restored old-process Network tasks fail until the user creates a new task with a current route. OS VPN/firewall policy remains authoritative. The API explorer supports the optional field, example requests, and strict UUID validation.

## Document preview leases and scoped archives

The following operations use the same API prefix, `files.read`, workspace allowlist, key/anonymous policy, CORS, request history and per-second/per-minute/active-response limits as content reads. No new anonymous permission or arbitrary document URI parameter is introduced.

| Method | Path | Input |
|---|---|---|
| POST | `/workspaces/{workspaceId}/prepare-preview?generation=N` | JSON `{id: DOCUMENT_ID}`; document-provider workspaces only |
| POST | `/workspaces/{workspaceId}/close-preview?generation=N` | JSON `{lease: LEASE_UUID}` |
| GET, HEAD | `/workspaces/{workspaceId}/archive?generation=N&path=PARENT&ids=JSON_IDS` | Optional parent and selected direct-child IDs |

Preview bodies are strictly bounded to 1 KiB and contain one canonical UUID field. Preparation returns `{url,size,etag,mime,lease}`. `url` is an integration API URL, not a browser-cookie URL: subsequent HEAD/GET/close requests still need the same API authority. Another key, a browser password cookie, or merely knowing the lease ID does not adopt the lease. Revoking the key or changing/removing the workspace ends it. See the [descriptor lease details](DIRECTORY_API.md#document-provider-preview-leases) for the eight-FD limit, 120-second idle lifetime, metadata validation and cancellation boundaries.

```javascript
async function readPreviewPrefix(base, token, workspaceId, generation, documentId) {
  const headers = {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'};
  const endpoint = `${base}/workspaces/${encodeURIComponent(workspaceId)}`;
  const prepared = await fetch(`${endpoint}/prepare-preview?generation=${generation}`, {
    method: 'POST', headers, body: JSON.stringify({id: documentId}),
  });
  if (!prepared.ok) throw new Error(`HTTP ${prepared.status}`);
  const lease = await prepared.json();
  try {
    const response = await fetch(new URL(lease.url, base), {
      headers: {Authorization: `Bearer ${token}`, Range: 'bytes=0-65535', 'If-Match': lease.etag},
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.arrayBuffer(); // One bounded prefix, not a whole-source mirror.
  } finally {
    await fetch(`${endpoint}/close-preview?generation=${generation}`, {
      method: 'POST', headers, body: JSON.stringify({lease: lease.lease}),
    });
  }
}
```

A generic media element cannot add a Bearer header by itself; the returned API URL does not bypass authorization. The product's browser workspace uses its separate scoped Cookie preview routes. `version=ETAG` remains supported on leased content for pinned readers, alongside `If-Match`; this is not durable `.ls` recovery or cross-restart resume.

Archive `path` identifies the parent: an empty root, a filesystem-relative directory, or an issued opaque document-directory ID. If supplied, `ids` is a URL-encoded compact JSON array of 1–128 unique IDs **directly under that parent**. Each ID is bounded to 4,096 bytes, the decoded array to 8,192 bytes, and the whole encoded query to 8 KiB. Selected folders are traversed recursively; omitted `ids` means the whole selected directory. Do not send display names, absolute paths or provider URIs. A document archive opens one original descriptor at a time, not a whole-tree cache. ZIP output is not resumable. The console exposes both GET and HEAD; its GET result is only a bounded binary sample, not a saved complete archive.

For document-provider `GET /workspaces/{workspaceId}/state`, send only `generation` and optional opaque `path` (not the filesystem `ids` query). The response is `{generation,path,refreshFromStart:true,watchId,stamp,observing}`. It reports short-lived current-directory invalidation, not file ETags or a complete diff. Establish the first state baseline before accumulating pages, and restart the current directory from its beginning when the watch identity/revision changes. `observing:false` does not mean unchanged; use explicit foreground refresh. The existing filesystem state response remains available as a separate schema alternative.

## Large selected ZIP downloads

For thousands of selected entries, use a short-lived selection ticket instead of putting IDs in the URL. Both endpoints below require the existing `files.read` scope and access to the selected workspace. They retain the normal API authentication, CORS, rate limits and request history; no additional anonymous permission is enabled.

| Method | Workspace-relative path | JSON body / result |
|---|---|---|
| POST | `/prepare-archive?generation=N` | `{path:"",ids:["FILE_ID",...]}` → `{selection,selectedEntries,expiresIn,downloadUrl}` |
| GET / HEAD | `/archive?generation=N&selection=UUID` | The selected ZIP / its response headers |
| POST | `/cancel-archive?generation=N` | `{selection:"UUID"}` → `{cancelled:true}` |

The API prefix is `/api/legnasend/v1/integration/workspaces/{workspaceId}`. `path` is required, including `""` for the root. Use a filesystem-relative parent directory or an issued document-directory ID, never an absolute path or a provider URI. `ids` must contain 1–20,000 unique, nonempty direct-child IDs. Each ID is limited to 4,096 UTF-8 bytes and has no control characters; the parent is limited to 4,096 UTF-8 bytes without NUL. The entire prepare JSON is at most 2 MiB. Larger selections must be split explicitly, not silently truncated.

Prepare stores bounded selection metadata; it does not enumerate the archive or cache ZIP bytes. `selectedEntries` counts explicitly selected entries, not recursive files or successful saves. Selected directories recurse when GET actually plans the archive, subject to the existing scan, depth, name, I/O and archive concurrency limits. Unknown-size/virtual provider entries and unsafe paths do not become downloadable merely because preparation succeeded.

```sh
# selection.json contains {"path":"","ids":[...]} from the current directory listing.
ORIGIN='http://HOST:PORT'
BASE="$ORIGIN/api/legnasend/v1/integration"
WORKSPACE='WORKSPACE_UUID'
GENERATION='1'
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' --data-binary @selection.json \
  "$BASE/workspaces/$WORKSPACE/prepare-archive?generation=$GENERATION" > ticket.json
# Read selection and downloadUrl from ticket.json. The URL contains no key.
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  "$ORIGIN$DOWNLOAD_URL" --output selected.zip
# To cancel this ticket and its active streams:
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' --data "{\"selection\":\"$SELECTION\"}" \
  "$BASE/workspaces/$WORKSPACE/cancel-archive?generation=$GENERATION"
```

`downloadUrl` uses the integration namespace and still needs the same API authority. A different key, an independently issued grant, or a browser password cookie cannot adopt an API ticket. Do not put a Bearer token in a URL. The browser workspace has separate same-origin Cookie routes and receives a browser URL instead.

The absolute 120-second lifetime limits **new GET/HEAD and retry admission**, not the duration of an already admitted archive. `expiresIn` is remaining whole admission seconds (1–120), not a renewable timeout. An admitted archive can continue after admission closes; explicit cancellation, grant expiry/revocation or workspace closure/replacement still stops it. Cancel can reach an active stream after admission expiry. Inactive expired/unknown tickets return 410; another caller gets 403. Malformed input returns 400; capacity exhaustion is reported rather than discarding selections. Limits are four tickets per workspace owner/caller, 64 globally and 16 MiB of retained selection metadata. Do not automatically repeat prepare after losing its response: that could allocate a second ticket.

A `selection` query must not be combined with `path` or `ids`. The legacy inline selection remains compatible at 1–128 IDs and the existing 8 KiB query budget. Ticket downloads are streamed ZIP archives, not partial archive resume or a change to the original LocalSend protocol.

The API explorer exposes both mutations, validates the same selection bounds and asks for in-page confirmation. Only this prepare operation receives a 2 MiB JSON-body allowance through the local console bridge (with a bounded 16 KiB envelope); other operations keep their smaller operation-specific limits. Console GET output remains a bounded response sample, not a saved complete ZIP. Use an actual download client to save the archive. Rejected HTTP/1 archive/preview control requests drain only known bodies up to 64 KiB within 100 ms; larger, unknown or slower bodies explicitly close the connection. HTTP/2 receives no `Connection` header.

## Document-provider upload parents

A key explicitly granting files.upload for a workspace can upload to its Android document tree independently of browser allowUpload, subject to existing system write/create authority. Add optional query parent: empty for root, or a current listing directory ID for a child. path is relative to that parent, never a content URI. A 201 receipt echoes parent. The explorer derives the field from the contract, shows the parent ID in its in-page confirmation and preserves it in cURL/JavaScript/Python examples. Filesystem requests omit it. See [directory uploads](DIRECTORY_API.md#document-provider-uploads) for actual publication, cancellation and uncertain outcomes.

## Document workspace capture into native sending

`POST /workspaces/{workspaceId}/send` supports an explicit document-source variant. First read the workspace descriptor and require `capabilities.capture`. Supply current `instanceId`, workspace `generation`, a discovered `deviceId`, a new idempotency `requestId`, `sourceMode: "documentSnapshot"`, and `files: [{"id": "ISSUED_DOCUMENT_UUID"}]`. Optional `channelId` and `localRouteId` retain existing routing semantics. The key requires the existing `transfers.send`, `files.read` and wildcard authority. The API explorer has a source-mode selector and retains it in the request draft and examples.

- Absent `sourceMode` keeps the original filesystem contract, including each file's quoted `version`. Document mode rejects `version`, arbitrary native paths, duplicate IDs and mixed selection forms. Use 1–128 selected regular, seekable, known-size document files. Recursive folders, virtual/nonseekable sources and duplicate resolved output names are not accepted in this variant.
- The host captures files one at a time into its privately owned stage, computes SHA-256 and reads the same held descriptor again to check the captured bytes. Two actual capture workers share the existing filesystem capture budget, with fixed 256 KiB buffers; provider operations retain their separate real-operation limits. This detects observed changes, not a provider-atomic snapshot of an entire directory.
- Only a complete verified selection enters the existing persistent queue. Workspace/listener changes are checked through the final queue-copy commit; failed captures clean only owned files after actual descriptor work ends. Queue ownership precedes release of the temporary capture stage. The original LocalSend handshake and file upload protocol are unchanged.
- Preserve the same request ID, mode and selection after an unknown outcome. Changing mode is a different payload and cannot reuse the old request ID. Existing claim semantics remain: revocation/disconnect after host acceptance does not retroactively undo an accepted send; inspect the task and use explicit cancellation. A 202 receipt is queue acceptance, not receiver completion.

This adds verified captured-byte sending, not persistent provider content versions, provider resumable downloads or automatic recursive-folder transmission.

## Source-end notification management

The optional native recovery extension retains an independent private outbox when the sender cancels, removes or discards a recoverable source. Ending a local task and confirming remote partial-file cleanup are separate results. The management API exposes only redacted notice metadata; cleanup credentials, recovery keys, native paths and stored route addresses are never returned.

| Method and route | Required key scope | Result |
|---|---|---|
| `GET /native-tasks/source-end` | `nativeTasks.read` and `*` | `{notices: [...], truncated: boolean}` |
| `POST /native-tasks/source-end/{noticeId}/retry` | `nativeTasks.control` and `*` | `{notice: {...}, accepted: true}` |

Both require an actual valid key even when anonymous reading is enabled. Each notice requires `id`, `version`, `peerLabel`, `name`, `state`, `attempts`, `updatedAtUnixMs`. Terminal `removed` or `publishedPreserved` notices may also contain `cleanup: {receiptId, removedFiles, unlinkedBytes}` from an actual receiver receipt. Missing data remains absent, not zero. See [cleanup receipt details](SOURCE_END_CLEANUP_RECEIPTS.md) for validation and logical-byte semantics. Read at most 512 notices within the bounded response budget; `truncated` explicitly reports omitted entries. IDs and versions are canonical UUIDs. No live task epoch is required: the outbox survives removal of the task and host restart.

```sh
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  "$BASE/native-tasks/source-end"
# Use id/version from that response. Generate REQUEST_ID once per user retry.
# Preserve this exact JSON after a timeout; do not silently choose a new ID.
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"version":"NOTICE_VERSION_UUID","requestId":"REQUEST_UUID"}' \
  "$BASE/native-tasks/source-end/NOTICE_UUID/retry"
```

Idempotency is scoped to one notice and its most recent retry: a newer request replaces the saved retry reference, so replaying an older request may return 409. It is not a global permanent receipt table. A stale version or conflicting reuse of a request ID returns 409. Invalid UUIDs, extra fields or a malformed body return 400. Retry intent is persisted before acceptance; a storage failure is not a successful dispatch. HTTP 200 with `accepted: true` means scheduled only. Refresh the list to observe the outcome; never translate it to “file deleted.” The in-app API explorer offers the same body fields, in-page confirmation and cURL/JavaScript/Python examples in all four maintained locales.

States:

- `pending`, `waitingPeer`: awaiting dispatch or rediscovery of the original peer. An obsolete address is not blindly reused.
- `sharedSource`, `busy`: another task still references the recovery source, or the receiver still owns an active/publishing transaction. No forced deletion occurs.
- `authorizationRequired`, `unknown`: authority or cleanup outcome needs attention; neither means the cache has been removed.
- `removed`: the receiver returned a durable cleanup receipt for its owned partial data.
- `publishedPreserved`: the file was already published and is retained.
- `expired`, `unsupported`, `superseded`: notification authority expired, the peer/source did not negotiate it, or a newer attachment replaced it. These are not cleanup receipts.

Only the separately negotiated source-end credential authorizes receiver cleanup; a public management key, an old v2 session token or a recovery UUID alone does not. Published files are protected. Legacy LocalSend peers still use the original protocol and whole-file retry; they do not acquire this extension implicitly.

## Persisted workspace content observations

Workspace descriptors, directory pages and directory-state responses now carry five separate observation fields. This implementation is awaiting validation; it does not change the existing configuration `generation` or any per-file conditional download contract.

| Field | Meaning |
|---|---|
| `contentEpoch` | UUID for the observed source identity; null until the host confirms persisted state |
| `contentRevision` | Persisted nonnegative observation counter, at most 9007199254740991 |
| `contentKnowledge` | `observed` for confirmed bounded metadata observations, otherwise `unknown` |
| `lastObservedAt` | Last persisted observation time in Unix milliseconds, or null |
| `dirty` | Whether observations need revalidation or persistence remains uncertain |

An observation is not an entire-tree hash, file SHA, or proof that every offline change was captured. Startup and source/listener changes become unknown. Watch notifications mark a scope dirty; a bounded foreground reread checks that scope before clearing it. A newer hint cannot be cleared by a read that began earlier. Successful controlled uploads enqueue confirmed changes; bursts may merge into one revision rather than one revision per file.

The host persists state before acknowledging it to the HTTP server. Pending or failed writes expose unknown state, never an optimistic committed revision. Changing names, visibility or access settings does not masquerade as content change. Replacing the source establishes a separate epoch. File `ETag`/`If-Match`, directory cursor validation, permissions and download cache identity keep their existing semantics. Do not use these fields to enable document-provider partial resume or to infer deletion of a download cache.

The native workspace list and browser toolbar show compact observation tags. Existing callers can continue using configuration `generation`; they do not send these fields in upload or native LocalSend protocol requests.
