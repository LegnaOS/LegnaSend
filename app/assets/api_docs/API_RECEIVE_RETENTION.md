# Receive-cache retention API

This guide extends the [integration API settings contract](INTEGRATION_API.md#settings-response-and-writes). All examples use the actual existing listener and `/api/legnasend/v1/integration` prefix. The API must be enabled. Use a key explicitly granting `settings.read`, `settings.write` and the global workspace grant `*`; anonymous access does not gain these capabilities. Read-only clients need only `settings.read` and `*`.

## Values and scope

`POST /settings/update` accepts one field per request:

```json
{"version":"VERSION_FROM_READ","field":"receiveCacheRetentionDays","value":7}
```

`value` must be a JSON integer between **−1 and 3650** inclusive. `-1` keeps registered native receive leftovers until explicit manual cleanup; `0` allows immediate automatic cleanup; positive values retain them for that many days. The native settings UI offers −1, 0, 1, 7 and 30; the API also accepts other integers in range. Strings (`"7"`), booleans (`true`), floating-point JSON tokens (`7.0`), `null` and out-of-range values are rejected, not coerced.

This setting applies to registered non-resumable native staging after an unexpected exit; ordinary cancellation and non-resumable failures still clean their transaction cache. Negotiated durable recovery uses a separate absolute one-day lease, retaining confirmed blocks on transport failure; this setting does not extend it. Startup/API cleanup preserves valid leases, while explicit local manual cleanup can reclaim inactive owned caches. Active records, outputs and identity mismatches remain protected. Summary reason `durable_resume` means recovery records were checked; `durable_resume_failed` denotes storage-check failure, not reclaimed space. See the [durable contract](NATIVE_DURABLE_RESUME.md). Workspace uploads, private workspace-export copies and Android document-provider transactions are separate. Retention does not provide partial resume for the original LocalSend protocol.

Updating this setting persists and synchronizes policy; **it does not run cleanup**, bypass age, stop a transfer or restart the listener. API `POST /cache/cleanup` still requires `cache.clean` and respects retention. Only the separately confirmed local receive-cache maintenance dialog overrides age; ownership, header and active-writer protection remain in force. A timed entry becomes eligible on the next maintenance pass, not at an exact scheduled deletion instant.

## Read saved and effective state separately

`GET /settings` and a successful update return the ordinary versioned settings snapshot plus a required top-level `receiveCacheRetention` object. Example excerpt:

```json
{
  "version": "64_HEX_DIGEST_FROM_THE_HOST",
  "settings": {"receiveCacheRetentionDays": 7},
  "pendingRestart": [],
  "receiveCacheRetention": {
    "effectiveDays": 7,
    "automaticCleanupPaused": false,
    "busy": false,
    "error": null
  }
}
```

The example omits unrelated settings. `settings.receiveCacheRetentionDays` is the saved integer preference; it is not proof that native configuration succeeded.

| Runtime field | Type and meaning |
| --- | --- |
| `effectiveDays` | Integer −1…3650, or `null` when the actual native policy has not been confirmed |
| `automaticCleanupPaused` | Boolean; whether automatic native-cache cleanup is currently paused |
| `busy` | Boolean; a settings policy operation is in progress |
| `error` | `null`, `invalid`, `save`, `apply`, or `restore` |

`invalid` denotes damaged saved preferences; `save` is a persistence failure, `apply` a synchronization failure, and `restore` a failed preference recovery. The host queries actual native policy after failures where possible. A returned `effectiveDays` can therefore differ from the saved preference. Read every field; neither `error != null` nor a saved value alone determines whether automatic cleanup is paused. An unknown native policy or uncertain preference recovery is kept paused.

`automaticCleanupPaused` is the synchronization safety gate, **not the retention mode**. A successfully applied manual policy can report `effectiveDays: -1` and `automaticCleanupPaused: false`: automatic maintenance may run but retains eligible native leftovers because manual retention is active. This never bypasses age or active-writer checks. Unknown policy (`effectiveDays: null`) and an in-progress change (`busy: true`) report a paused gate. A reconciled old policy after `save`/`apply` failure may leave the gate unpaused while preserving the diagnostic.

## Optimistic concurrency and outcomes

1. Read `GET /settings` and retain its exact `version`.
2. Review the saved and effective states before preparing one mutation.
3. Send one update with that version. Wait for persistence and native policy acknowledgement.
4. On `409 settings_changed`, read again and decide whether the intent still applies; do not simply replace the version and blindly resubmit.
5. On `409 settings_busy`, wait for the existing operation, then read state again. Do not queue automatic mutations.
6. On `503 host_operation_failed`, read actual state. Persistence rollback or native synchronization may have failed; the failure is not proof that nothing changed.
7. After a network error, host deadline or `outcome_unknown`, query state rather than replaying the mutation automatically.

The version includes saved settings, pending-restart state **and** the complete retention runtime snapshot. It is an optimistic content digest, not a monotonically increasing revision. Transient `busy` or error-state changes can invalidate a version. Equal snapshots can produce equal versions. These operations are not request-ID deduplicated. The in-app API explorer validates integer input, uses in-page confirmation for each write, and displays response JSON including actual-state diagnostics in four supported interface locales.

## cURL

Requires `curl` and `jq`. `BASE` is the actual listener URL. Keep tokens in process environment rather than URLs. If using HTTPS, configure the trusted device certificate in curl; do not suppress certificate verification.

```sh
BASE='http://HOST:PORT/api/legnasend/v1/integration'
DAYS=7
SNAPSHOT=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/settings")
VERSION=$(printf '%s' "$SNAPSHOT" | jq -er '.version')
BODY=$(jq -nc --arg version "$VERSION" --argjson days "$DAYS" \
  'if ($days|type)=="number" and ($days|floor)==$days and $days>=-1 and $days<=3650
   then {version:$version,field:"receiveCacheRetentionDays",value:$days}
   else error("Expected integer -1..3650") end')
curl --include --request POST \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" -H 'Content-Type: application/json' \
  --data-binary "$BODY" "$BASE/settings/update"
# Read state after an uncertain or failed outcome; no automatic repeat POST.
curl --fail-with-body -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/settings"
```

For a deliberate negative test against a fresh version, replace the JSON value with `true` or `"7"`: the endpoint returns 400 instead of treating either as an integer. Do not use jq string output (`--arg days`) for the valid request. jq normalizes integral numbers to integer JSON; the wire contract, not a language's number representation, controls acceptance.

## JavaScript

The browser still follows configured CORS and TLS policy. `token` should come from an explicit secret input; do not embed it in URLs or committed source.

```javascript
const base = 'http://HOST:PORT/api/legnasend/v1/integration';
const headers = {Authorization: `Bearer ${token}`};
async function readSettings() {
  const response = await fetch(`${base}/settings`, {headers, credentials: 'omit'});
  if (!response.ok) throw new Error(`Read failed: ${response.status}`);
  return response.json();
}
async function setRetention(days) {
  // No Number(days): that would silently accept true or numeric strings.
  if (!Number.isInteger(days) || days < -1 || days > 3650) {
    throw new TypeError('Expected integer -1..3650');
  }
  const snapshot = await readSettings();
  const response = await fetch(`${base}/settings/update`, {
    method: 'POST', credentials: 'omit',
    headers: {...headers, 'Content-Type': 'application/json'},
    body: JSON.stringify({version: snapshot.version, field: 'receiveCacheRetentionDays', value: days})
  });
  console.log(response.status, await response.json());
  if (!response.ok) console.log('Current state:', await readSettings());
  // A caller handles network errors by reading state, never by repeating POST.
}
await setRetention(7);
// setRetention(true) and setRetention('7') reject locally.
```

## Python

Python `bool` is a subclass of `int`; use `type(days) is int`, not just `isinstance(days, int)`.

```python
import json, os, urllib.request, urllib.error

BASE = 'http://HOST:PORT/api/legnasend/v1/integration'
HEADERS = {'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN']}

def call(method, route, payload=None):
    data = None if payload is None else json.dumps(payload).encode('utf-8')
    headers = {**HEADERS, **({'Content-Type': 'application/json'} if data is not None else {})}
    request = urllib.request.Request(BASE + route, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=40)
    except urllib.error.HTTPError as response_error:
        response = response_error
    with response:
        return response.status, json.loads(response.read(262144))

def set_retention(days):
    if type(days) is not int or not -1 <= days <= 3650:
        raise TypeError('Expected integer -1..3650')
    status, snapshot = call('GET', '/settings')
    if status != 200:
        raise RuntimeError(('Read failed', status, snapshot))
    result = call('POST', '/settings/update', {
        'version': snapshot['version'], 'field': 'receiveCacheRetentionDays', 'value': days})
    print(result)
    if result[0] != 200:
        print('Current state:', call('GET', '/settings'))
    # Network exceptions propagate; inspect current state before deciding anew.

set_retention(-1)
# set_retention(True), set_retention('7'), set_retention(7.0) reject locally.
```

For HTTPS use a trusted device CA with `ssl.create_default_context(cafile='DEVICE_CA.pem')` and pass the context to `urlopen`; provide a client certificate if the listener requires it. The original transfer protocol, certificate identity checks and file formats are unchanged.
