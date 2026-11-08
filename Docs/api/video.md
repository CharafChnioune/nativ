# Nativ Video API, contract 1

The active Nativ server is canonical for Video and Music. This is a Nativ API,
not OpenAI Videos compatibility. Every endpoint, including input/media HEAD,
ranges, posters and SSE, requires the existing server bearer key. Never place it
in query strings. Clients namespace all IDs and caches by the `store_id` returned
by `/v1/video/info`. Every mutation additionally requires `X-Nativ-Store-ID`
matching that info response. Missing=428; changed=409. The default local port is
8181. Never retarget a saved intent to another store.

These examples require an installed, enabled, license-accepted and explicitly
experimental/qualified profile. A catalogue entry alone is not readiness. Local
inference and paid cloud qualification were not run in this implementation.
Provider credentials use named server profiles/environment configuration; generation
JSON cannot choose a credential, path, endpoint or public input URL.

```sh
export NATIV_URL='http://127.0.0.1:8181'
# Set NATIV_KEY privately from the existing configured server key.
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/info"
export NATIV_STORE_ID='<store_id returned by info>'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/models"
```

## Submit and recover one user intent

Persist the exact request JSON, server/store identity and one random idempotency
key **before** sending. Reuse all of them after timeout/relaunch. Only an explicit
new Generate/Regenerate action gets a new key. Missing keys return 400; changed
content under the same key returns 409. Keys persist for the job lifetime; no job purge is implemented. `info` currently
returns store_id, contract_version, modality and numeric limits. Read capabilities
and readiness from `models`; do not infer a published post-purge retention window
or additional capability flags from info.

```sh
export VIDEO_INTENT='replace-with-one-persisted-random-uuid'
curl -fsS -X POST "$NATIV_URL/v1/video/generations" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" -H "Idempotency-Key: $VIDEO_INTENT" \
  -H 'Content-Type: application/json' \
  -d '{"model":"ltx-2.5-distilled-q8-local","operation":"text_to_video", "prompt":"A wooden boat drifts across a calm lake at sunrise", "output_preset":"draft-landscape","audio_mode":"native_generated","seed":42,"allow_remote":false}'
```

The server returns 202 and a durable job immediately, before compute admission.
Requested, accepted and independently measured output remain distinct. The LTX
preset is exactly 704×448, 97 frames and 24 FPS. It is neither exact 16:9 nor 720p.
Cloud provider-determined FPS/frame counts remain null until actual media probing.

Upload bytes first for image-to-video. Multipart field `file` contains a still
PNG/JPEG/WebP; file names and MIME declarations cannot replace byte validation.

```sh
curl -fsS -X POST "$NATIV_URL/v1/video/inputs" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" -F 'file=@first-frame.png;type=image/png'
# Save the returned input_id, then use another persisted intent identity:
curl -fsS -X POST "$NATIV_URL/v1/video/generations" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" -H 'Idempotency-Key: persisted-i2v-intent-uuid' \
  -H 'Content-Type: application/json' \
  -d '{"model":"wan2.2-ti2v-5b-q8-local","operation":"image_to_video","prompt":"The paper boat begins to float", "output_preset":"wan-draft-landscape","audio_mode":"silent","allow_remote":false,"inputs":[{"input_id":"REPLACE_INPUT_ID","role":"first_frame","transform":{"version":1,"fit_policy":"contain","crop":null,"background":"#000000"}}]}'
```

Crop coordinates are normalized after EXIF orientation with a top-left origin.
`crop` is `{x,y,width,height}` within `[0,1]`, positive nonempty area, and allowed
only with `fit_policy: crop`. The server deterministically materializes RGB/sRGB
PNG at the accepted target size, strips metadata and records the derivative hash.
T2V rejects references. Wan and Runway reject last-frame references. H3 remains
license-gated; ref2va is not a still-input API capability.

Cloud generation is deliberate, for example `model: runway-gen4.5`,
`audio_mode: silent`, `output_preset: cloud-landscape`, `duration: 5`,
`allow_remote: true` with an already enabled account. Seed accepts 0…4294967295.
Runway prompt length is at most 1,000 UTF-16 units. LTX cloud accepts a curated
model/resolution/FPS/duration matrix and native or silent audio; unsupported
controls fail before any generation POST.

## Observe and act on the same job

```sh
export JOB_ID='REPLACE_JOB_ID'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/generations/$JOB_ID"
curl -N -H "Authorization: Bearer $NATIV_KEY" -H 'Last-Event-ID: 0' \
  "$NATIV_URL/v1/video/generations/$JOB_ID/events"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" "$NATIV_URL/v1/video/generations/$JOB_ID/cancel"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" "$NATIV_URL/v1/video/generations/$JOB_ID/resume"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" "$NATIV_URL/v1/video/generations/$JOB_ID/retry-download"
```

States: queued, recovery_hold, preparing, running, finalizing, retrieval_pending,
succeeded, cancel_requested, cancelled, interrupted, failed and submission_unknown.
Progress is stage-scoped, never an invented overall completion estimate. SSE
reconnect uses ordered IDs; old pruned cursors resynchronize current state.
Disconnecting an observer does not cancel work.

Resume applies only to never-dispatched recovery_hold work. A known remote
operation recovers by polling its original ID. An ambiguous paid POST cannot be
resumed/replayed. Retry Download requires `capabilities.retrieval_supported:true` and a known
operation (LTX V2/Runway), and fetches that existing result; expired/unrecoverable
outputs fail without regeneration. Local cancellation stops owned worker children
before releasing compute. LTX cancellation cannot promise provider stop or refund.
Runway never DELETEs a known completed task; the remaining provider completion
race is exposed honestly.

Unconfirmed external work retains its capacity reservation. An explicit override
can acknowledge possible overlapping execution/charges without resubmitting:

```sh
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" -H 'Content-Type: application/json' \
  -d '{"acknowledge_possible_execution_and_charges":true}' \
  "$NATIV_URL/v1/video/generations/$JOB_ID/release-remote-reservation"
```

## Original media and ownership

```sh
export ASSET_ID='REPLACE_ASSET_ID'
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/assets/$ASSET_ID"
curl -f -H "Authorization: Bearer $NATIV_KEY" -o original.mp4 "$NATIV_URL/v1/video/assets/$ASSET_ID/content"
curl -I -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/assets/$ASSET_ID/content"
curl -f -H "Authorization: Bearer $NATIV_KEY" -H 'Range: bytes=0-1023' \
  "$NATIV_URL/v1/video/assets/$ASSET_ID/content" -o first-kib.bin
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/assets/$ASSET_ID/usages"
```

Content has an ETag, safe filename and proper 206/416 ranges. No provider URL,
absolute server path or credential is returned. Remote native playback uses an
authenticated bounded local cache; export/GET do not create permanent usages.

Session endpoints are GET/POST `/v1/video/sessions` and PATCH
`/v1/video/sessions/{id}` (`title`/`hidden`). Hiding never deletes originals.
Asset references use PUT/DELETE `/v1/video/assets/{id}/references/{reference_id}`
with reserve/finalize, expected revision and durable released tombstones. An
uncertain reserve blocks deletion. DELETE `/v1/video/assets/{id}` moves an unused
asset into recoverable trash; live usages return 409. POST
`/v1/video/assets/{id}/restore` preserves the same ID. Inputs expose GET,
GET `/content`, DELETE by input ID; accepted-job pins block deletion.

## Canonical transform preview, setup and stop

POST `/v1/video/inputs/{input_id}/transform` accepts
`{width,height,transform}` with the same store precondition. Width/height are
integers 1…4096, their product is at most 8,294,400, and an input has at most 32
prepared previews. The response includes derivative_id, transform and both
original/derivative hashes. GET
`/v1/video/inputs/{input_id}/derivatives/{derivative_id}/content` returns its
canonical PNG for an authenticated composer preview. This does not submit a job.

```sh
curl -fsS -X POST "$NATIV_URL/v1/video/inputs/REPLACE_INPUT_ID/transform" \
  -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  -H 'Content-Type: application/json' \
  -d '{"width":704,"height":448,"transform":{"version":1,"fit_policy":"contain","crop":null,"background":"#000000"}}'
```

GET `/configuration` and `/runtimes` report named settings/readiness and exact
setup/qualification data. PUT `/configuration/{profile_id}` accepts the settings
described in [Music API setup](music.md#setup-and-orderly-server-stop), never keys
or paths. POST `/runtimes/{runtime_id}/{action}` accepts `{profile_id}` for install,
repair, remove or cancel-install. All mutations require the store header; license
review and experimental setup are explicit. Reads never download weights.

GET `/server-state` reports shared pending/active/queued/setup counts, unresolved
remote reservations and stopping/ready_to_stop. POST `/prepare-stop` (202) stops
admission for **both** Music and Video, holds queued work for explicit recovery
and requests active cancellation. Poll ready_to_stop before stopping the server;
remote work and charges may continue. It is unrelated to closing a workspace.

```sh
curl -fsS -H "Authorization: Bearer $NATIV_KEY" "$NATIV_URL/v1/video/server-state"
curl -fsS -X POST -H "Authorization: Bearer $NATIV_KEY" -H "X-Nativ-Store-ID: $NATIV_STORE_ID" \
  "$NATIV_URL/v1/video/prepare-stop"
```

The generated OpenAPI preserves base Nativ endpoints and adds typed per-profile
Music/Video requests, responses, headers, uploads, ranges and SSE. Metadata JSON
is at most 128 KiB; multipart input envelope is bounded to 25 MiB+64 KiB, with a
25 MiB still-byte and 40M decoded-pixel limit. Individual provider derivatives
have smaller limits. Generation errors use
`{error:{code,message,field,retryable,job_id}}`; malformed typed query parameters
can use FastAPI's validation-error shape. Output originals/import are at most
2 GiB. No paid request or real-model qualification is implied by these examples.
