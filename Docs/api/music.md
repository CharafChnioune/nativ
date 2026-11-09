# Nativ Music API, contract 1

The active Nativ server owns the canonical Music/Video library. Every request,
SSE connection, media GET and HEAD requires its existing bearer key. Provider
credentials stay in private server configuration; generation JSON cannot contain
credentials, endpoints, local paths or a hidden fallback.

Every **mutation** additionally requires `X-Nativ-Store-ID`. Read `/info` first,
then save that identity with your intent. Missing store preconditions return 428;
a different store returns 409. Never silently change a saved intent to another
server/store. The default local port is **8181**.

```sh
export NATIV_URL='http://127.0.0.1:8181'
# Set NATIV_KEY privately to the existing Nativ server bearer credential.
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/info"
export NATIV_STORE_ID='<store_id returned by info>'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/models"
```

`info` returns `store_id`, `contract_version`, `modality` and numeric `limits`.
Capabilities, qualification and current readiness come from `models`, not the
model name or a presumed info capability flag. Jobs/idempotency records remain
for their job lifetime; no job purge is implemented. Do not assume an advertised
post-purge tombstone window. Reads do not install models or generate music.
The server's generated OpenAPI documents typed requests/responses, required
headers, provider-specific fields, errors, ranges and SSE.

## One persisted generation intent

Before POST, durably save exact JSON, server/store identity and one random
Idempotency-Key. After a lost response/relaunch, retry the same bytes/key/store.
Only a deliberate new Generate/Regenerate action gets a new key. Missing keys
return 400; changed request content under an existing key returns 409. Defaults,
randomized fields and the accepted profile are frozen once. Retrying an uncertain
paid operation never submits another provider generation.

```sh
export MUSIC_INTENT='<one persisted random UUID for this user intent>'
curl -fsS -X POST "$NATIV_URL/v1/music/generations" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  -H "Idempotency-Key: $MUSIC_INTENT" -H 'Content-Type: application/json' \
  -d '{"model":"stable-audio-3-small-local","prompt":"Warm instrumental soul with Rhodes piano and restrained drums","instrumental":true,"duration_seconds":30,"seed":42,"output_format":"wav","allow_remote":false}'
```

This requires the selected profile to be configured, installed, license-accepted
and ready; local qualification is not inferred from fixture tests. Submission
returns 202 with a stable job/store/session and frozen `request`, before compute
admission. An omitted session creates one atomically. Requested/accepted settings,
provider-reported effective parameters and independently measured asset metadata
remain distinct.

The model catalogue is authoritative. MiniMax MLX/remote GPU, Stable Audio
local/hosted and Lyria have different duration/seed/lyrics/audio contracts.
ACE-Step stays listed but disabled (its runtime runs PyTorch on MPS, not MLX):
readiness reports that reason and runtime install/repair return 409. Lyria
and hosted MiniMax reject unsupported hard duration/seed controls. MiniMax local
and remote GPU use a duration ceiling. Instrumental MiniMax local/remote maps to
`[instrumental]`; hosted MiniMax has a native instrumental option. Stable Audio
profiles support instrumental descriptions, not lyric-conditioned singing.
An enabled remote profile requires `allow_remote:true` on that individual intent.

## Observation, cancellation and recovery

```sh
export MUSIC_JOB_ID='<job_id from submission>'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID"
curl -N -H "Authorization: Bearer $NATIV_KEY" -H 'Last-Event-ID: 0' \
  "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID/events"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID/cancel"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID/resume"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID/retry-download"
```

SSE is ordered state/stage JSON with keepalive comments, not playable audio.
Progress may be null. Reconnect with the last event ID; pruned cursors receive a
current-state snapshot. Polling is supported; disconnecting never cancels work.
States are queued, recovery_hold, preparing, running, finalizing,
retrieval_pending, succeeded, cancel_requested, cancelled, interrupted, failed and
submission_unknown. Success requires independently validated durable media.

Resume applies only to never-dispatched recovery_hold work after configuration
revalidation. Interrupted local inference is not a resumable model state. Retry
Download requires the saved profile capability `retrieval_supported:true` and a
known existing operation; a billing/request trace ID alone is insufficient. It
never regenerates.
An ambiguous paid POST without a known operation remains submission_unknown.
Provider execution/charges may continue after observation is cancelled.

Unconfirmed remote work keeps its capacity reservation. An explicit acknowledged
release affects Nativ admission only; it neither refunds charges nor makes replay
safe:

```sh
curl -fsS -X POST "$NATIV_URL/v1/music/generations/$MUSIC_JOB_ID/release-remote-reservation" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  -H 'Content-Type: application/json' -d '{"acknowledge_possible_execution_and_charges":true}'
```

## Sessions, originals and references

GET `/sessions` and `/generations` accept `cursor`/`limit`; generations optionally
filters `session_id`, sessions optionally includes `include_hidden=true`. Lists
return `items` and `next_cursor`. POST `/sessions` accepts `{title}`; PATCH
`/sessions/{session_id}` accepts title/hidden. All mutations use the store header.
Hiding a session never deletes originals.

```sh
export MUSIC_ASSET_ID='<asset_id from a succeeded job>'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/assets/$MUSIC_ASSET_ID"
curl -f -H "Authorization: Bearer $NATIV_KEY" \
  "$NATIV_URL/v1/music/assets/$MUSIC_ASSET_ID/content" -o original.wav
curl -I -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/assets/$MUSIC_ASSET_ID/content"
curl -f -H "Authorization: Bearer $NATIV_KEY" -H 'Range: bytes=0-1023' \
  "$NATIV_URL/v1/music/assets/$MUSIC_ASSET_ID/content" -o first-kib.bin
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/music/assets/$MUSIC_ASSET_ID/usages"
```

Use the actual asset format/filename: MP3 bytes do not become WAV by renaming.
Content supplies length/type, ETag, safe disposition and 206/416 byte ranges.
Credentials never appear in media URLs. GET/export does not create a live usage.

PUT `/assets/{asset_id}/references/{reference_id}` accepts
`{phase:"reserve"|"finalize", expected_revision, owner:{...}}` (owner <=4 KiB).
Reserve a new reference with revision 0, then finalize the returned revision.
DELETE that path accepts `{expected_revision}` and records a released tombstone.
A stale finalize cannot revive it; a later attachment needs a new reference ID.
Live/reserved usages block DELETE `/assets/{asset_id}` with 409; inspect usages
and explicitly unlink only the chosen owner. POST `/assets/{asset_id}/restore`
restores the same identity. Originals remain service-owned.

## Setup and orderly server stop

GET `/configuration` returns named settings/readiness. PUT
`/configuration/{profile_id}` accepts the booleans `enabled`,
`experimental_enabled`, `license_accepted`, `allow_local_http`, `account_eligible`,
`separate_license_approved`, and strings `endpoint`, `account_id`, `region`
(`global`/`china`). It does not accept secrets or paths. GET `/runtimes` exposes
exact model bytes, licenses, setup status and qualification. POST
`/runtimes/{runtime_id}/{action}` accepts `{profile_id}` with action install,
repair, remove or cancel-install. These mutations require the store header and
explicit license/setup decisions; ordinary reads never start setup.

GET `/server-state` reports pending/active/queued/setup counts, unresolved remote
reservations, stopping and ready_to_stop. POST `/prepare-stop` (store header,
202) stops **shared Music and Video admission**, holds queued work for recovery
and requests active/setup cancellation. Poll server-state until ready_to_stop
before terminating the server. This is an explicit server-stop action, not a
workspace change. It does not guarantee remote provider stop/refund.

Errors are `{error:{code,message,field,retryable,job_id}}`; malformed typed query
parameters can additionally use FastAPI's validation-error shape. Metadata JSON
is bounded to 128 KiB; output download/import is at most 1 GiB for Music. See
[Video API](video.md), [Music setup](../features/music.md) and
[qualification evidence](../development/music-runtime-qualification.md).
