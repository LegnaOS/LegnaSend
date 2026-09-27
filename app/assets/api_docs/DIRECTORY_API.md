# Directory workspace browser API

[简体中文](DIRECTORY_API_ZH.md)

This covers implemented browsing, downloads and opt-in uploads, not the entire integration API. The local app's Workspaces tab remains the source of durable settings. The separate integration API can now create workspaces from locally approved sources and manage explicitly granted workspaces, including closed-source/route and password changes; this browser-cookie namespace does not grant administrative writes. Independent workspace passwords are implemented. The separate [integration API core](INTEGRATION_API.md) now has scoped keys and configurable budgets; those do not replace this browser-cookie contract. Native policy/key management is now available in the API tab; the in-app request console supports reads and confirmed uploads/management; device/owned-task/cache controls and supported application settings are available in the separate integration namespace. Original `/api/localsend/v2` endpoints are unchanged.

## Access and identity

The app must be running with its receiving server enabled. Open a configured local directory explicitly; creation alone does not publish it. All directory routes share the app's actual listening port and HTTP/HTTPS setting. Use the address copied from the app, including a fallback port when applicable.

Workspaces can allow open access or require an independent password/PIN. Visibility only controls the public index: hidden workspaces remain reachable through their known route and obey the same password policy. Local root paths are not returned. Closing/removing a workspace revokes new requests and its active downloads, without deleting source files or restarting unrelated sessions. Renaming/hiding changes its configuration generation, but preserves already-open streams on the same root.

## Document-provider workspaces

Android document-tree sources use the same workspace index, slug URLs, password cookies and integration authorization as filesystem directories. The private tree URI is never a public file ID or root path. A descriptor adds `backend: "filesystem" | "documents"` and `capabilities: {archive, capture, events, preview, resume, state}`. Check each capability before exposing an operation; document previews use the explicit descriptor lease below; inspect each other returned capability. Document workspaces default to `readOnly: true`, `allowUpload: false`; browser uploads may be enabled after checking the existing write grant. This does not change ordinary filesystem functionality.

For a document workspace, root `path` is empty and subdirectory `path` is the returned opaque directory entry `id`, not a slash-joined filename. Keep readable breadcrumb labels separately. Do not decode or manufacture document IDs. `size: null` means unknown, not an empty file; `downloadable: false` excludes such entries from download actions. A listed known size is preliminary: opening must still confirm a regular seekable descriptor and matching size. Virtual files, pipes and unsupported providers fail explicitly rather than being copied into a hidden local mirror.

Document listing reads at most 100 provider rows per request and may return fewer matching names with a non-null cursor. A provider may internally materialize more rows; this is not a promise of provider-side lazy I/O. Loading/error results are explicit failures, not complete empty directories. A changed or expired cursor requires a fresh listing. `stamp` is an opaque, backend-specific listing marker, not a strong content version. Revisiting or refreshing performs a new provider query; live events and anchor-preserving external-change refresh are not claimed for this backend.

Document downloads use one original-byte response with `Accept-Ranges: none` and no ETag. Do not use persistent `.ls` recovery or assume repeat requests identify identical content. Opt-in provider uploads and selected-file capture are described below; event streams remain unavailable for this backend; state is a backend-specific current-directory invalidation hint, not per-file metadata versions. Preview uses an explicitly prepared short-lived descriptor lease, described below; ordinary downloads do not gain cross-request validators. API clients must not force these operations merely because a filesystem workspace supports them. Source selection requires local system authorization; the administrative API still cannot submit arbitrary tree URIs. Closing a workspace ends its own reads and provider state, not unrelated shares or the system grant used by another application feature.

## Routes

| Method | Path | Result |
|---|---|---|
| GET | `/` | Visible workspace index page |
| GET | `/{slug}/` | Workspace browser page |
| GET | `/{slug}/?meta` | `{id, name, slug, generation, readOnly, allowUpload, uploadApproval, protected}` |
| GET | `/api/legnasend/v1/workspaces` | `{workspaces: [descriptor], temporary: boolean}`; visible entries only |
| GET | `/api/legnasend/v1/workspaces/{id}/files?generation=N&path=PATH&cursor=CURSOR` | Incremental directory page |
| GET | `/api/legnasend/v1/workspaces/{id}/state?generation=N&path=PATH&ids=IDS` | Foreground directory/visible-entry metadata validation |
| GET | `/api/legnasend/v1/workspaces/{id}/events?generation=N&path=PATH` | Bounded directory invalidation event stream |
| GET, HEAD | `/api/legnasend/v1/workspaces/{id}/files/{fileId}/content?generation=N` | Original file bytes or response headers |
| POST | `/api/legnasend/v1/workspaces/{id}/unlock` | JSON `{generation, password}`; sets an HttpOnly authorization cookie |
| POST | `/api/legnasend/v1/workspaces/{id}/logout` | JSON `{}`; revokes the current browser grant |
| GET | `/share` | Existing temporary sharing, when enabled |

`generation` is required on list/content requests. Read it from the current descriptor; do not invent it. `path` is a URL-encoded root-relative directory path for filesystem sources, or an opaque directory ID for document sources; it defaults to the root. Omit `cursor` for the first page. Treat returned `fileId` and cursor values as opaque. File IDs are scoped to a workspace; they are not access tokens. Never infer authorization from hidden names or encoded IDs.

A page returns `{entries, cursor, generation, path, filter, scanned, stamp, offset, anchorPending, anchorMissing}`. Each entry has `{id, name, directory, size}`. `size` is a file byte count; do not use directory sizes as recursive totals. A non-null cursor means there may be more entries, even when the current page is empty. Filesystem cursors can be retried idempotently while valid. Document-provider cursors include an expected offset; an already-consumed cursor returns 409 and requires a fresh listing instead of silently skipping entries. Revalidate metadata and restart the list after a changed/expired cursor; do not append a new generation to an old list. Enumeration order is filesystem-defined, not a global sort.

Each page returns at most 100 visible entries and examines at most 512 directory entries. The registry retains at most 128 cursor records, valid for 120 seconds. Blocking list operations are limited to eight; download bodies to 32 globally/eight per workspace. These are concurrency/resource bounds, not configurable per-second/minute rate quotas. Internal `.ls` and `.legnasend*` names, symlinks, special files and unsupported path components are excluded. Reads do not follow descendant symlinks.

Directory queries always use `/`, including when the host runs Windows. URL-encode the relative query once; never submit an absolute drive/UNC path or decode returned file IDs as URLs. The native root and mobile permission references belong only to local configuration. See platform paths.

## Password authorization

The public index and known-route descriptor expose the name and `protected` flag, not the verifier, local path or file names. Protected list/content/HEAD/Range requests return 401 until unlocked. Unlock accepts only JSON, up to 4 KiB with a five-second body deadline, and checks the current generation. Password values do not belong in URLs or query parameters. Browser Origin must exactly match the actual host/scheme; cross-site submissions are rejected. Non-browser clients may omit Origin.

Successful unlock returns `{unlocked: true, expiresIn: 3600}` and a random, workspace-scoped cookie with `HttpOnly`, `SameSite=Strict`, a one-hour absolute lifetime and `Secure` on HTTPS. There is no token in the JSON response, localStorage or sessionStorage. Use a cookie jar for native API clients. Different hosts/IP addresses have separate browser cookies. Cookies are not restored as server grants across a process restart.

Changing/removing protection or closing the workspace revokes its previous grants and interrupts old downloads. Renaming/hiding preserves current grants, but clients must use the new configuration generation. Logout revokes only the presented grant and stops its active streams; other browser grants and workspaces continue. Expiry and bounded-session eviction also stop affected streams. There are at most 64 grants per workspace.

Unlock requests have fixed budgets: five per source IP/workspace/minute and 30 globally/minute, plus two password workers. A 429 includes `Retry-After` (one second for worker saturation). These protective defaults are independent of the new integration API quotas. Only salted PBKDF2-HMAC-SHA256 verifiers are persisted, with 600,000 iterations; raw passwords are not saved. The local app accepts 4–128 Unicode characters, including numeric PINs.

HTTPS protects credentials and content in transit. A password alone does not encrypt HTTP or saved files. The HTTP page labels this distinction; the receiving app controls HTTPS.

```sh
umask 077
BASE='http://HOST:PORT'
# Substitute the current ID/generation. The JSON travels in the request body.
# Use the actual HTTP/HTTPS address shown by the host app.
curl -c cookies.txt -H 'Content-Type: application/json' \
  --data-binary @- "$BASE/api/legnasend/v1/workspaces/ID/unlock" <<'JSON'
{"generation": GENERATION, "password": "PASSWORD"}
JSON
curl -b cookies.txt "$BASE/api/legnasend/v1/workspaces/ID/files?generation=GENERATION"
curl -b cookies.txt -c cookies.txt -H 'Content-Type: application/json' \
  --data '{}' "$BASE/api/legnasend/v1/workspaces/ID/logout"
```

## Preview and content search

For filesystem workspaces, the same content endpoint accepts `preview=1` to opt into allowlisted inline types for raster images, audio/video and plain text. The default (or `preview=0`) remains an attachment. HTML, SVG, scripts and unknown types stay `application/octet-stream` attachments with `nosniff`; there is no raw-document iframe. Browser codec support is checked and the original download remains available.

1. Send an authenticated HEAD with the current generation and `preview=1`.
2. Keep the returned strong ETag, including its quotes. Set `version` to that exact value using URL encoding on later HEAD/GET requests; keep the same cookie and generation. This lets native media controls enforce the version without custom request headers.
3. The server maps `version` to an `If-Match` precondition; changed metadata returns 412. If both are supplied, the header must match the pinned value. Invalid version syntax/preview flags return 400. A version is not an authorization token and never replaces the workspace cookie.

```sh
curl -I -b cookies.txt "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION&preview=1"
# ETAG is the exact quoted value from HEAD, not a password.
curl -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'preview=1' \
  --data-urlencode 'version=ETAG' -H 'Range: bytes=0-1023' -o preview-chunk.bin
```

The reader performs TXT/Markdown content search through these authenticated range requests, not a new public search endpoint or server-side index. It retains the existing 64 KiB reads, 4 MiB reading cache, separate 2 MiB search cache, virtual rows, encoding/wrapping controls and 1,000-match limit. Small Markdown files retain whole-document formatting; larger documents now use lazy complete-block sections and bounded virtual rendering. Offline Mermaid/Markmap and shared image zoom/pan are implemented. Oversized individual syntax blocks still retain source reading/search; see the current README and its evidence for exact budgets and pending acceptance.

While a preview is visible, a foreground HEAD check is scheduled every three seconds after the previous check, with a five-second request deadline. Changed or missing resources stop the old reader and retain an in-page retry that obtains a fresh HEAD identity; revoked grants clear protected content and reopen authorization; other network failures clear cached content and offer an in-page retry. Closing, navigation or page hiding aborts reads, terminates the Markdown worker and releases media sources. This polling is not instantaneous push revocation or a guaranteed background timer. The ETag is a metadata validator, not a content hash or an immutable snapshot of a file being edited.

## Download and recovery

HEAD provides size, ETag and range support. Authenticated GET accepts one byte range, `If-Match` and `If-Range`. Store and validate the response ETag before assembling ranges; a configuration generation is not a content checksum. File changes can reject conditional reads or terminate an in-progress stream. Completion requires the expected byte count, not just a successful initial status.


```sh
BASE='http://HOST:PORT'
# Replace the route with one created in the app.
curl "$BASE/workspace1/?meta"
curl "$BASE/api/legnasend/v1/workspaces"
# ID, GENERATION and FILE_ID are returned by the preceding responses.
curl --get "$BASE/api/legnasend/v1/workspaces/ID/files" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path='
curl -I "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION"
curl -b cookies.txt -H 'Range: bytes=0-1023' -H 'If-Match: ETAG' \
  "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION" \
  -o chunk.bin
```

| Status | Meaning / client action |
|---|---|
| 200 / 206 | Complete response / validated partial response |
| 401 | Missing, expired or revoked grant / incorrect password |
| 403 | Cross-site or mismatched Origin |
| 408 / 413 / 415 | Unlock body deadline / size / content type rejected |
| 400 | Missing generation, unsafe path, malformed ID, duplicate query or cursor/path mismatch |
| 404 | Unknown/closed workspace, missing/inaccessible source or forbidden symlink |
| 405 | Unsupported HTTP method; this cookie namespace does not grant administrative writes |
| 409 | Configuration or directory changed; refetch descriptor/list |
| 410 | Expired/evicted cursor or workspace stopped during preparation |
| 412 | ETag condition failed; do not combine old and new bytes |
| 416 | Unsatisfiable/malformed range |
| 429 | Concurrency or login budget exhausted; respect Retry-After on unlock |



## Foreground updates and bounded browsing

`GET /api/legnasend/v1/workspaces/{id}/state` uses the same generation, workspace Cookie and root-confined path rules as listing. Supply the encoded relative `path` and optional comma-separated `ids` from **that same directory**, at most 64 unique file/directory IDs and an 8,192-byte total query. The response is `{generation, path, stamp, entries: [{id, size, directory}], missing: [id]}`. It reads only requested metadata, not file contents or a recursive tree, and shares the eight-slot blocking-I/O budget. `missing` means the entry is missing, inaccessible or no longer an allowed regular file/directory; symbolic links are never followed. Password revocation/source closure also invalidates the response.

The optional `stamp` on file-list pages and the state response is a 64-character metadata validator. It is not a file hash or immutable snapshot. A changed stamp invalidates old pagination; same-size content edits still require the content ETag/HEAD checks described above. Filesystem timestamp granularity varies, so state polling is heuristic validation, not a guarantee of observing every intermediate edit. The separate event stream below adds invalidation hints, not immutable content versions. The integration API file-page schema documents the optional field; the new Cookie state route is not an added Bearer console operation.

After each completed check, the page waits 5–30 seconds before checking visible entries again, depending on unchanged results, failures and latency. Hidden/offline pages cancel work and recheck on foreground/online restoration; background timer delivery is not assumed. When no preview is open, changes refresh the current window; deep readers use bounded anchor relocation to retain the visible entry and focus. If the anchor disappears or the budget is exhausted, **Refresh** explicitly returns to the beginning. Old and new pages are never appended together. Access revocation clears rows without opening a repeating password modal. A removed child directory returns to its parent. Active managed downloads are not cancelled by listing refresh.

Forward prefetch uses positive scroll speed and observed request latency, at most two viewport heights ahead and no more than one scroll-triggered attempt per 200 ms. Loading remains serial; manual load remains available. A short or empty first window may request at most two additional pages, 200 ms apart, to avoid stopping at excluded cache entries; failures do not trigger that fill loop. Retained metadata is capped at 1,000 entries, 16 pages and 4 MiB measured as serialized UTF-16 data, not total JavaScript heap. Evicted pages leave at most 64 small continuation bookmarks; **Previous entries** and **Browse from start** expose the bounded section honestly. Bookmarks use the existing expiring server cursors: expired/evicted/changed sources restart instead of silently mixing pages. File-count limits are not imposed on the shared source directory.

### Directory change events

`GET /api/legnasend/v1/workspaces/{id}/events?generation=N&path=RELATIVE_DIRECTORY` uses the **browser workspace cookie**, not an integration Bearer key. Supply the current positive generation; omit/empty `path` for the root. Only `generation` and `path` are accepted: unknown/duplicate keys or a query over 8,192 bytes are rejected, stale generation returns 409, and the same root confinement, unsafe-name and descendant-symlink exclusions as listing apply. Missing or inaccessible directories return 404; an identity change while installing the watcher returns 409. Authorization is checked before subscribing.

Success is `text/event-stream`, `Cache-Control: no-store`, `X-Accel-Buffering: no`. Three named events share the same minimal payload:

```text
event: ready
data: {"generation":1}

event: invalidate
data: {"generation":1}

event: heartbeat
data: {"generation":1}
```

`ready` confirms subscription setup; `invalidate` requests an ordinary authorized list/state refresh. Bursts coalesce over 500 ms instead of buffering every filesystem event. Heartbeats are sent after approximately 15 seconds without an emitted event. No filenames, native paths, file bytes or watcher error details appear in events. This is a **nonrecursive** watcher for the currently browsed directory, not a recursive change feed or durable event journal; there are no event IDs, replay or exactly-once guarantees. Read content using the existing HEAD/ETag/Range checks.

At most 16 streams globally and four per workspace run at once; excess returns 429. Watcher installation failure returns 503. A stream expires after about 90 seconds and closes when its workspace closes, its configuration generation changes, or the browser grant is revoked/expires. Slots and the watcher are owned by the stream and released when it ends. Subscription capacity is separate from API-key request quotas.

The browser watches only in a visible/online browsing context. It closes stale subscriptions on directory/access/navigation changes and reconnects with bounded 1–30 second exponential delay. Errors trigger the existing state probe; 5–30 second foreground polling remains available when EventSource/watchers fail or are absent. Invalidation preserves the existing reading-position/focus and pending-update behavior; it does not interrupt independent downloads. Notification delivery and background scheduling are not hard real-time guarantees.

```sh
curl -N -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/events" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=relative/subfolder'
```

## Browser batch downloads

These optional browser routes use the **existing approved download session or workspace cookie**, not an integration API key. They work over HTTP and HTTPS and do not change original LocalSend peer transfers. Select **Download all / selected · ZIP** in temporary sharing, or **Download folder · ZIP** for the current folder or a child directory. One uncompressed ZIP64 response preserves relative names, subfolders and empty directory records. Files omitted from a temporary share, including empty directories absent from its file list, are not inferred.

| Method | Path | Parameters |
|---|---|---|
| GET, HEAD, POST | `/api/legnasend/v1/web/archive` | Required `sessionId`; optional repeated `fileId`, or one `prefix` ending in `/` |
| POST | `/api/legnasend/v1/web/archive?check=1` | Metadata-only legacy preflight, returns `{entries: N}` |
| POST | `/api/legnasend/v1/web/archive?prepare=1` | Same form; returns `{entries: N, downloadUrl: "/api/legnasend/v1/web/archive?sessionId=...&selection=..."}` |
| GET, HEAD | `/api/legnasend/v1/web/archive?sessionId=...&selection=...` | Approved session and prepared selection; do not combine with `fileId` or `prefix` |
| GET, HEAD | `/api/legnasend/v1/workspaces/{id}/archive` | Required current `generation`; optional root-relative `path` (empty means the whole workspace) |

Temporary GET queries are limited to 8 KiB; POST uses `application/x-www-form-urlencoded`, at most 1 MiB, with a ten-second body deadline. Supply `sessionId` exactly once. Omit `fileId` for all files; repeated IDs select a set. A prefix and explicit IDs are mutually exclusive. Sessions remain bound to the approved source IP and current share. Browser POST Origin must match the actual listener and cross-site submissions are rejected. HEAD/preflight checks metadata and access, not file bodies, and is not a reservation: actual download checks access again.

Browser temporary shares use preparation followed by an ordinary GET download link with the download attribute, not a POST document navigation. This keeps the /share pane mounted and does not create a ZIP Blob. Preparation validates the complete selection first and stores only selector metadata: eight retained selections per active share, each bounded by the 1 MiB request limit. Links expire after 120 seconds and can be reused before expiry (HEAD does not consume them); expiry or eviction returns 410, and clicking Download prepares a fresh link. The ticket never replaces session/IP authorization. A changed shared-file-list version invalidates the ticket; active download source checks remain in effect. Existing direct archive GET/POST and check=1 clients remain supported.

```javascript
// Use the already-approved session; fileIds contains the exact selected IDs.
const form = new URLSearchParams([['sessionId', sessionId], ...fileIds.map(id => ['fileId', id])]);
const response = await fetch('/api/legnasend/v1/web/archive?prepare=1', {
  method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: form
});
if (!response.ok) throw new Error('Archive preparation: HTTP ' + response.status);
const {downloadUrl} = await response.json();
const link = document.createElement('a');
link.href = downloadUrl; link.download = '';
document.body.append(link); link.click(); link.remove();
```

Directory downloads use the same password cookie and configuration generation as lists/content. The scan does not follow symlinks and excludes internal `.ls` / `.legnasend*` entries and special files. Each file opens under the configured root, with its planned metadata ETag and size rechecked. This is **not an atomic filesystem snapshot**; files added after the scan are not included. Removal, metadata changes, authorization revocation or a short read fail the response instead of publishing a valid truncated archive.

Limits: two global archive jobs, at most 100,000 emitted entries, 16 MiB of UTF-8 names, 4 KiB per name, 64 directory levels and a 15-second directory scan deadline. Traversal examines at most 100,000 entries, including excluded entries. Names reject traversal, case-insensitive collisions, file/parent conflicts and common Windows reserved/invalid components. A job opens one source at a time, bounds each queued output to 64 KiB with two slots, and waits at most 30 seconds for a source open/read. A disconnected downloader cancels its producer; the sender does not prebuild a ZIP and the web page does not fetch it into a Blob. Metadata/central records remain bounded separately from file contents.

Successful responses use `application/zip`, attachment filenames, exact `Content-Length`, `Cache-Control: no-store`, `X-LegnaSend-Archive-Entries` and **`Accept-Ranges: none`**. ZIP is generated afresh, so an archive retry starts again; no archive ETag/checkpoint or partial-recovery guarantee is exposed. The existing single-file Range/ETag contract is unchanged. Possible preflight errors include 400 invalid selection/path, 401/403 access, 404/410 missing source, 409 conflicting paths/stale generation, 413 budget, 429 active jobs and 504 scan deadline. Errors after headers interrupt the browser download, not turn it into a success.

```sh
BASE='http://HOST:PORT'
# Get SESSION_ID from the existing approved prepare-download flow, on this client.
curl --fail --get "$BASE/api/legnasend/v1/web/archive" \
  --data-urlencode 'sessionId=SESSION_ID' -o shared.zip
# POST supports many IDs without putting the selection into a long URL.
curl --fail "$BASE/api/legnasend/v1/web/archive" \
  --data-urlencode 'sessionId=SESSION_ID' \
  --data-urlencode 'fileId=FIRST_ID' --data-urlencode 'fileId=SECOND_ID' -o selected.zip
# Obtain cookies as described above if the directory is protected.
curl --fail -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/archive" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=relative/subfolder' -o folder.zip
```

### Save location

Ordinary browser downloads use the browser's configured directory (usually Downloads), including its ask-each-time setting. The page always exposes **Save location**; ordinary LAN HTTP explains browser-managed saving. Supporting secure contexts may authorize a directory, after which the **same single-file Download action** automatically uses existing `.ls` pause/resume. Resetting to the browser default does not remove registered tasks. There is no separate cache-download button. Browser-default ZIPs remain browser-managed; authorized-directory original-file batches now use the journal below. Full mobile/provider acceptance remains separate. A website does not set arbitrary local paths or control the browser's temporary-file extension. [Browser capability reference](https://developer.chrome.com/docs/capabilities/web-apis/file-system-access).

## Original-file batches in an authorized directory

Set **Save location** in a browser with directory access, IndexedDB and Web Locks. The existing all/selected/folder buttons then say **files**, not ZIP. Resetting to the browser default changes new actions without deleting tasks. Ordinary LAN HTTP still uses browser-managed ZIP saving, not arbitrary path-string filesystem access.

Each batch creates a new child directory under the destination, avoiding existing names. Preserve original names (up to 255 UTF-8 bytes per component), subfolders and empty directories; never overwrite an output. Reject cross-platform unsafe components, case/Unicode-normalization and file/parent conflicts during planning. The existing approved temporary list or cookie/generation-bound directory pagination supplies metadata; this is not an atomic filesystem snapshot.

Persist manifests in pages of at most 100 items and keep progress in a separate small record. Limits: eight retained batches, 100,000 items, 16 MiB each for names/path-tree accounting, 32 MiB serialized metadata, 64 path components and 10,000 list requests/five minutes for planning. Interrupted incomplete planning restarts enumeration before creating destination files.

One batch runs per page; subsequent batches queue. Two file jobs reuse the original single-file ETag/.ls writer and shared network budget. A batch Web Lock prevents two tabs from advancing one journal. Durable completed-file receipts and cursor-before-retirement ordering prevent duplicate files after progress-write interruption. Completed files are not downloaded again.

Reload restores paused batches. Click Continue to renew destination permission and use the current approved temporary list or workspace cookie/generation; manifests contain no passwords/session approvals. Retry checks unfinished sources and fetches missing verified ranges, never silently substituting changed/revoked sources. Registry identity includes host/scheme/port. Removal uses an in-page modal and removes only owned partial data; completed/user files and directories stay. This is original-file batch recovery, **not ZIP Range recovery**.

Registry version 2 preserves existing single-file stores and adds batches/manifests. Saved-file counts, committed/staged bytes, speed and controls are localized. Browser storage testing does not prove platform Downloads grants, background lifetimes or physical mobile/file-provider behavior.

## Opt-in directory uploads

In the host app, open **Workspaces → Upload permission → Allow browser uploads**. New and migrated workspaces default to read-only. This permission accepts uploads directly from browsers that can access the workspace; password-protected workspaces still require their own cookie. Uploading is not enabled by an integration API bearer key, visibility or HTTPS alone.

The browser offers file/folder selection and dropping into the current directory. Jobs capture workspace ID, generation and destination at selection time. Two uploads run at once; up to 10,000 selected entries use a 24-row paged queue. Empty folders are supported when the drag-entry API exposes them. Plain HTTP uses ordinary file inputs, not the secure-context download-directory picker. The sender retains files only while the page is open; retry sends the whole file, not a byte-range continuation.

`POST /api/legnasend/v1/workspaces/{id}/upload?generation=N&path=RELATIVE_PATH`

- Required headers: `X-LegnaSend-Upload: 1`, `Content-Type: application/octet-stream`, exact `Content-Length`; the body is the raw file. Browsers set length from the selected File.
- `path` is relative to the workspace root, encoded once as a query value. Parent directories are created without following symlinks. Reject absolute/parent paths, reserved names and internal cache names. Never construct an ID from a local filesystem path.
- Add `directory=true` with a zero-length body to create an empty directory. An existing name returns 409; it is not merged or overwritten by this operation. Parent directories created while saving a file may be reused.
- Response: **201**, JSON `{"path":"folder/example.txt","size":123,"sha256":"…","directory":false}` only after explicit EOF, exact-length validation and no-overwrite publication. SHA-256 describes received bytes, not a client-supplied integrity proof.
- Errors: 400 invalid arguments/body, 401 missing or revoked workspace grant, 403 read-only/cross-origin/denied storage access, 404 missing workspace, 409 stale generation/name conflict, 411 missing length or transfer encoding, 415 content type, 429 active upload limit, 500 storage/publication failure.
- Limit: two active operations per workspace across generation changes and eight globally, with 64 KiB chunks and eight queued chunks per worker. Existing downloads retain their independent budgets.
- Requests reject cross-site browser context and mismatched Origin. The custom header prevents ordinary cross-origin forms; no permissive CORS upload endpoint is added. CLI clients without Origin still require the marker and workspace credentials where applicable.
- Turning uploads off, changing workspace generation, closing/destroying the workspace, or revoking a browser grant cancels unfinished operations. Native-path publication and revocation have a shared commit gate: after revocation is acknowledged, an old native-path writer cannot subsequently publish. Provider publication already in progress uses the confirmed-or-unknown outcome described below. A file committed before that boundary remains; ordinary metadata/upload-permission edits do not cancel unrelated downloads.

```sh
BASE='http://HOST:PORT'
# Encode the full relative path; cookies are required for protected workspaces.
curl -b cookies.txt -H 'X-LegnaSend-Upload: 1' \
  -H 'Content-Type: application/octet-stream' --data-binary @example.txt \
  "$BASE/api/legnasend/v1/workspaces/ID/upload?generation=GENERATION&path=folder%2Fexample.txt"
curl -b cookies.txt -H 'X-LegnaSend-Upload: 1' \
  -H 'Content-Type: application/octet-stream' --data-binary '' \
  "$BASE/api/legnasend/v1/workspaces/ID/upload?generation=GENERATION&path=empty-folder&directory=true"
```

Same-name failures preserve the existing file. The browser rechecks metadata to distinguish a stale generation before offering in-page rename/retry. Network errors, busy responses and name conflicts pause the queue rather than repeating thousands of failed requests. Completed jobs refresh the current directory without clearing the upload queue.


### Separate key-authorized upload API

The browser upload route above still requires its own upload permission, request marker and applicable workspace cookie; a Bearer key does not authenticate that route. The independent `POST /api/legnasend/v1/integration/workspaces/{workspaceId}/upload` now accepts explicit workspace-scoped `files.upload` keys, even when browser uploads are disabled. Existing read-only keys and anonymous callers do not gain write access. See the [integration upload calling guide](INTEGRATION_API.md#keyed-file-and-directory-uploads).

### Registered upload-partial cleanup

Browser and key-authorized directory uploads now create random `.legnasend-receive-<UUID>.part` staging files. Their bodies are still the original upload bytes, not an `.ls` container. When the host's private receive registry is configured, a durable `directory-upload-v1` export record binds the exact parent/file identity to the task before accepting body data. The app configures that registry before starting server isolates, using application-support/portable configuration storage; it does not place registry metadata in a publicly shared directory.

The app's startup receive-cache maintenance and manual cleanup can reclaim an interrupted registered upload after a process crash. Both registration and data-file locks protect a live writer. Cleanup checks the registered parent and file identity with no-follow opens; a changed identity, symlink, active lock, unavailable grant or ambiguous/failing deletion is retained rather than guessed safe. Each pass is bounded to 4,096 records / two seconds and reports retained/failure states; reported bytes are logical removed bytes, not guaranteed reclaimed filesystem capacity. Successful cleanup uses reason `interrupted_directory_upload`.

Only registered owned partial files qualify. Existing final files, source files, arbitrary user `.ls` files, prefix-matching but unregistered files and old `.legnasend-upload-*.part` remnants remain untouched. In-process cancellation may remove newly created empty parent directories; crash reconciliation does not scan/delete arbitrary source directories. A standalone core host that has not configured the private registry retains ordinary cancellation cleanup but does **not** gain startup crash reconciliation automatically. No original LocalSend endpoint or payload format changes.

## Batch cache retention

Original-file batches share the download panel’s manual/1/7/30-day retention setting. Expiry checks re-read journals under batch and file locks and clean only owned unfinished caches and metadata, preserving completed files and user directories. Active/queued batches, unknown permission and changed ownership are retained. HTTP 401/403 and transient network failures remain retryable; definitive source loss or version change cleans owned remnants, with a localized reason. This is browser-managed authorized storage, not ZIP Range support or native cross-restart resume.

## Per-batch browser upload approval

App-published workspaces advertise `uploadApproval: true`. `allowUpload` is the workspace’s write permission, not approval of any incoming request. The app requires **one host decision per browser selection/drop**, including a folder with thousands of files. New workspaces remain read-only. Explicit `files.upload` API-key authorization uses the separate integration namespace and does not inherit browser approval tokens. Original LocalSend endpoints and file formats are unchanged.

1. POST `/api/legnasend/v1/workspaces/{id}/prepare-upload` using the current browser cookie, `Content-Type: application/json` and `X-LegnaSend-Upload: 1`. Send `{requestId, generation, files: [{path, size, directory}]}`. `requestId` is a fresh canonical UUID v4, paths are workspace-root-relative, directories have zero size. Keep the manifest immutable.
2. The app’s pending tag opens an in-page batch summary, total size and lazy file preview. Accept or reject within the server’s 60-second deadline. Closing/back only hides the panel; it never stops native receiving or sharing.
3. Approval returns `{token, expiresIn: 1800, fileCount, totalBytes}`. Put the token in **`X-LegnaSend-Upload-Token`**, never the URL, for each existing `/upload` request. The token binds the workspace generation, source IP, browser authorization cookie and exact path/size/type. Every entry is consumed once; the original bytes still use the existing bounded two-request upload scheduler. Approval is not a completed transfer receipt.
4. To cancel the pending/unused remainder, POST `/cancel-upload-approval` under the same workspace, headers and cookie with `{requestId, generation}`. In the browser, canceling one item of an approved batch cancels its remaining batch; completed files stay intact. A failed file’s Retry or rename requests new approval for that item. Existing destination files are not overwritten.

Limits: 1 MiB manifest, at most 10,000 unique paths, safe-integer total size, 64 path components and 255 UTF-8 bytes per component; two pending batches per workspace and sixteen globally, plus sixteen live approved manifests per workspace. Cancellation has independent bounded admission so a full waiting queue can still be drained. Preparation rejects cross-origin requests. Outcomes include 400 invalid manifest, 401 lost browser grant, 403 declined/permission denied, 409 changed generation/canceled, 408 deadline, 429 capacity and 503 unavailable host responder. An upload without an applicable token returns 428 before writing. Declining a batch does not turn off the workspace’s upload permission.

Closing/changing a workspace, losing browser authorization, disconnecting or expiring a pending request invalidates that decision. Approved tokens are memory-only and not restored after restart. A raw core embedding that omits `uploadApproval` retains its explicitly configured direct-upload behavior; this backward-compatible field default is not the app’s published policy. Shared Flutter/mobile layout tests and local browser/bridge tests are distinct from Android/iOS device permission and background acceptance.

## Bounded refresh around a visible entry

A fresh `files` request may provide `anchor=FILE_ID`, using an entry from the current directory. The ID must decode to a safe relative path whose parent equals `path`; another directory is rejected. Omit the anchor on subsequent requests and follow `cursor`, keeping the same generation, path and filter. Authorization and root confinement are unchanged. The integration namespace supports this same parameter.

`anchorPending=true` means scanning has not reached that entry yet: continue the returned cursor even when entries are empty. Each request scans at most 512 candidates; the complete anchor search scans at most 32,768. `anchorMissing=true` means the entry is absent or the search budget was exhausted; offer browsing from the beginning instead of silently displaying unrelated results. `offset` counts matching visible entries skipped before the returned page, not a seek parameter. Once the anchor is found, entries follow the actual filesystem enumeration and existing pagination limits. This is relocation in a fresh enumeration, not a merge of old and new pages or a globally sorted snapshot.

The browser now uses this mechanism for deep-directory refresh and restores the existing window after reconnect or page restoration. Preview-source replacement/deletion retains a retry state; retry fetches a fresh identity before rebuilding the reader. Existing protected content is cleared on authorization loss.

Authorized-folder downloads offer configurable 1/2/4 file and range concurrency, opt-in bounded reconnect and bulk controls. These do not change ordinary browser-managed downloads. Completed receipts may be retired at capacity while all output files remain.

## Document-provider preview leases

For a workspace whose descriptor advertises `backend: "documents"` and `capabilities.preview: true`, prepare a preview rather than adding `preview=1` to an ordinary download URL:

```sh
curl -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"id":"DOCUMENT_ID"}' \
  "$BASE/api/legnasend/v1/workspaces/ID/prepare-preview?generation=GENERATION"
# {url,size,etag,mime,lease}
curl -I -b cookies.txt "$BASE$URL"
curl -b cookies.txt -H 'Range: bytes=0-65535' -H 'If-Match: ETAG' "$BASE$URL"
curl -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"lease":"LEASE_UUID"}' \
  "$BASE/api/legnasend/v1/workspaces/ID/close-preview?generation=GENERATION"
```

The returned URL retains `/files/DOCUMENT_ID/content` and adds `generation`, `preview=1` and `lease`. `version=ETAG` and `If-Match` are supported for the existing readers. Prepare/HEAD MIME values describe the same allowlisted inline representation; HTML, SVG and scripts are not preview types. Unknown size, virtual documents and nonregular/nonseekable descriptors remain unsupported.

A lease pins one original read descriptor without mirroring the source. There are at most eight live descriptor leases, each expiring after 120 seconds without successful HEAD/read activity. Every request checks that descriptor's metadata. The quoted ETag incorporates random lease identity and metadata, not a content digest or immutable snapshot; changed metadata rejects the old lease. Independent Range readers serialize individual bounded seek/read operations on the same descriptor, so concurrent requests cannot race a duplicated shared file offset.

Workspace generation changes, closure, authorization revocation and expiry end the lease. Browser close/navigation/page hiding explicitly release it; reopening is a new prepare, not a continuation of old cached offsets. The visible page's existing HEAD checks renew the lease. A syscall that ignores cancellation can retain its descriptor and real worker budget until it returns; the HTTP reader stops without claiming the OS call was interrupted. Ordinary attachment downloads stay unversioned and must not use this preview lease as persistent download resume.

## Document-provider selected ZIP and current-directory state

The existing authenticated `archive` route now accepts `ids`, a URL-encoded JSON array of 1–128 unique direct-child IDs under `path`. Omitting `ids` preserves whole-directory download; selected folders recurse. For document workspaces, `path` is empty or an issued directory UUID, never a joined display name. Each file is opened and streamed in turn from its original descriptor. No provider tree is mirrored and no complete archive is prepared on disk.

Output uses ZIP64 STORE with Unicode paths and explicit empty directory records under the safe `files/` prefix. Case-folded name collisions fail with 409, unsafe names with 400, and unreadable/virtual/unknown-size document entries with 501. A selected document outside its parent fails with 404 (invalid filesystem selection uses 400). The document scan is bounded to 30 seconds, 100,000 entries, 16 MiB of names and depth 64; the existing two-archive, eight-I/O and per-workspace eight-download budgets remain effective. Source changes, revocation and short reads abort the response without a successful central directory. This is not a snapshot or resumable archive, and does not change the original LocalSend transfer protocol.

Document `state?generation=N&path=OPAQUE_ID` returns a short-lived watch identity/revision with `refreshFromStart:true` and `observing`; it does not accept `ids` or return file-version entries. Watch capacity is bounded and expires when not refreshed. Loss of observer support is not proof that the directory is unchanged. Browser foreground polling establishes a baseline before collecting pages and refreshes the current directory from the beginning after an invalidation; explicit Refresh remains available. `capabilities.state` describes this backend-specific state hint; `capabilities.events` remains false.

A successfully registered document observer is only a hint, not a provider reliability guarantee. The foreground watch reuses a bounded retained listing cursor to keep compatible AOSP observers alive; a provider may still materialize an entire internal MatrixCursor. The application bounds retained handles and exposed pages, not the provider's private query cost. Manual refresh remains the fallback when observations are absent or unreliable.

## Large selection archive tickets

For a large selection, the browser uses `POST /api/legnasend/v1/workspaces/{id}/prepare-archive?generation=N` with JSON `{path:"",ids:[...]}`. `path` is required even at the root. Select 1–20,000 unique, nonempty direct-child IDs, at most 4,096 UTF-8 bytes per ID with no controls; the parent is at most 4,096 UTF-8 bytes with no NUL. The whole JSON body is limited to 2 MiB. IDs come from the current directory, not user-supplied source paths. This works for both confined filesystem and document-provider workspaces.

The result is `{selection,selectedEntries,expiresIn,downloadUrl}`. Follow `downloadUrl` using the same browser session; it identifies `archive?generation=N&selection=UUID`. Do not combine that query with `path` or `ids`. Preparation retains selection metadata only, not the complete directory, file contents or ZIP. `selectedEntries` counts explicitly selected entries, not all recursive descendants. GET performs the actual bounded archive scan and streams the ZIP using the existing checks and worker budgets. Preparation success is not a promise that every selected source remains available.

Tickets admit new HEAD/GET requests for an absolute 120 seconds, with no renewal. `expiresIn` reports remaining whole admission seconds, not a fixed download duration. An already admitted archive continues beyond admission expiry, unless cancelled, its authority expires/is revoked, or its workspace is closed/replaced. `POST /api/legnasend/v1/workspaces/{id}/cancel-archive?generation=N` with `{selection:"UUID"}` cancels exactly that ticket and its active streams, including admitted streams still running after the admission deadline. It returns `{cancelled:true}`; an inactive missing/expired ticket returns 410, and another caller returns 403. Cancellation never deletes source files.

Capacity is four tickets per workspace owner/caller, 64 globally and 16 MiB of retained metadata. A lost prepare response must not trigger an automatic prepare retry; unclaimed tickets expire. The browser and API authorities remain separate: an API ticket uses its integration URL and still needs the same Bearer authority. See the [integration examples](INTEGRATION_API.md#large-selected-zip-downloads). Existing inline archive selection remains compatible at up to 128 IDs within its query budget. This is an ordinary streamed download with a short metadata ticket, not a browser cache staging flow or an extension required by original LocalSend peers.

## Document-provider uploads

The local workspace Upload permission control can enable browser writes after checking an existing persisted read/write grant and root create capability. It never requests new system authority on behalf of a remote caller. Failed preflight preserves the previous read-only setting. Close the workspace, explicitly reselect it through the system picker and grant access when needed. Every actual write rechecks the current parent and authority.

Browser and integration uploads keep their existing separate endpoints and raw bodies. Document workspaces add query `parent`: empty means the tree root; otherwise it is a directory `id` issued by the current generation's listing. `path` is a validated name/relative path beneath that parent, never a document ID, absolute path or content URI. Filesystem workspaces remain root-relative and require parent omitted or empty.

The browser prepare-upload manifest may add the same top-level `parent`. Approval binds it along with generation, peer, cookie and exact path/size/type. Navigation never retargets an already selected task; retry obtains approval for the original parent. Unapproved bodies are not written. Explicit integration `files.upload` keys with a matching workspace grant remain independent of the browser allowUpload switch, but cannot bypass system write authority.

Use an owned .ls cache and separate export staging, verify length/hash, publish through the provider and read back the result before returning 201. Document receipts add `parent`, for example `{"parent":"DIRECTORY_ID","path":"folder/file.txt","size":123,"sha256":"…","directory":false}`. Empty folders retain directory=true and a zero-length body. Existing documents are not overwritten; unexpected provider renaming is not success under the requested name. Rollback touches only proven-owned newly created directories that remain empty.

Asynchronous provider publication is not advertised as POSIX atomic no-replace. Once actual commit begins, cancellation remains non-blocking and cannot relabel a confirmed publication as canceled. A browser disconnect during saving reports an unconfirmed result and pauses its queue; inspect the destination before retrying. Unknown outcomes retain reconciliation records, not a false cleanup claim. Stopping a listener drains only already delivered descriptor transactions' publish/release control; new begins stop and obsolete responses cannot affect the new listener.

### Capturing document files for native sending

Document workspace descriptors advertise `capabilities.capture` when the integration source-capture path is available. Use the explicit `documentSnapshot` body of the [workspace sending API](INTEGRATION_API.md#document-workspace-capture-into-native-sending), not a listing timestamp or preview lease as a fabricated strong version. This capability covers selected ordinary files, not automatic recursive folder capture or provider-level atomic content versions.
