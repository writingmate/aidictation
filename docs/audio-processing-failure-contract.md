# Audio processing failure contract

This contract applies to macOS, iOS and its keyboard extension, Android, and Windows.

## Top-down attempt lifecycle

Every platform follows the same six phases. Later optional work is never allowed to undo an
earlier durable result.

| Phase | Durable state | What must happen before moving on | Failure result |
|---|---|---|---|
| 0. Capture and finalize | none | Write every audio frame, monitor capture health, and close the container under a bounded stop/finalize deadline | Return to idle with a microphone or storage message. Never submit a truncated or unfinalized source as a normal recording |
| 1. Save source | none → `processing` | Move the finalized audio into managed storage and commit its stable recording ID | Stop before recognition. Do not claim the recording is saved unless both the source and record are durable |
| 2. Recognize speech | `processing` or `retrying` | Run one bounded local job or bounded sequential cloud requests; checkpoint completed leaves | `failed`, with source and the last durable ordered checkpoint |
| 3. Clean up text | active state, with complete raw text already available | Run one separately bounded optional cleanup pass | Raw text becomes the result on timeout, HTTP error, invalid/empty/truncated output, or unavailable cleanup |
| 4. Commit result | active → `success`, `failed`, or `cancelled` | Persist the terminal state before dismissing the workflow | The UI still becomes idle and explains that History could not be updated; startup recovery uses retained managed audio |
| 5. Deliver text | already `success` | Paste, insert, share, or hand off the durable text | Delivery failure never returns the recording to `processing`; the text remains available to copy or retry delivery |

The recording indicator belongs to phase 0. The visible processing indicator belongs only to phases
1–4. Clipboard access, app activation, usage reporting, analytics, and other delivery-side work must
not hold it open.

## Invariants

1. Allocate the stable recording ID and managed partial source before capture. Persist and validate the finalized source before recognition.
2. Every active attempt has one owner, a deadline, cancellation, and a terminal persisted state.
   Capture, finalization, recognition, and cleanup use distinct bounded stage deadlines; reaching the
   capture limit must still leave enough bounded time to close and validate the container.
3. A relaunch converts abandoned active work to a recoverable failure; it never displays an endless processing state.
4. A retry updates the same recording ID. It does not create duplicate history entries.
5. Recognition is the required stage. Optional cleanup may improve successful text, but cleanup failure, timeout, or empty output returns the raw transcript.
6. Chunk uploads run sequentially. Completed text is checkpointed in order, and cleanup runs once after the complete merge.
7. Never delete the only recoverable audio copy. Never claim that a recording was saved until durable persistence succeeds.
8. Every callback carries its recording ID, attempt ID, and deletion generation. Stale callbacks have no effect.

## Persisted states

| State | Meaning | Allowed next states |
|---|---|---|
| `processing` | Source is durable and one attempt owns the recording | `success`, `failed`, `cancelled` |
| `retrying` | A retry owns the same durable recording | `success`, `failed`, `cancelled` |
| `success` | Final text is durable; raw audio remains available under retention policy | `retrying` |
| `failed` | Work ended; source and any completed partial text are durable | `retrying` |
| `cancelled` | The user or a replacement attempt stopped the work; source remains recoverable | `retrying` |

If a platform does not expose `cancelled` separately in its UI, it may persist it as `failed` with a
cancellation reason. It must still be terminal and retryable.

## Request policy

| Failure | Attempts | Recovery |
|---|---:|---|
| Complete `200` response | 1 | Accept only after the full body and strict response schema are available; `202` and `206` are not complete transcription results |
| Permanent `4xx` (`400`, `401`, `403`, `404`, `409`, `422`, and every other `4xx` except `408`, `413`, `429`) | 1 | Fail immediately; preserve source and partial text; show an actionable settings/request message |
| `408`, `429`, `500...599` | Up to 3 total | Retry with bounded backoff; honor `Retry-After` and cap the delay at 10 seconds |
| Transient connection loss, DNS/connect failure, request timeout | Up to 3 total | Same bounded retry policy |
| I/O timeout or disconnect while draining a successful response body | Up to 3 total | Treat it as a transient transport failure; retry the current request without replaying completed chunks |
| `413` | No replay of completed chunks | Split only the rejected audio leaf, continue sequentially, and stop at a bounded depth/minimum size |
| Cancellation | 1 | Cancel the request/export/decoder immediately; do not retry or allow a late result to mutate state |
| Invalid response or decode error | 1 | Fail; preserve source and completed partial text |
| Local engine timeout/failure | 1 per attempt | Cancel/reset the engine, persist failure, allow an explicit retry |
| Cleanup timeout/error/empty output | Cleanup is bounded separately | Keep the successful raw transcript; do not convert recognition success into failure |

## Local and persistence failures

| Failure | State and recovery |
|---|---|
| Capture write, recorder health, or container finalization fails/stalls | Stop or detach the recorder under a bounded deadline, return the UI to idle, and do not start recognition from a source known to be truncated or unfinalized |
| Source move or initial journal write fails | Do not start recognition. Return to idle with a storage message. Only say the recording was saved if the durable commit actually succeeded |
| Audio export, split, decode, or local model setup fails | Cancel/reset that operation, persist `failed`, retain the original source, and allow retry |
| A successful response body times out or disconnects before it is complete | Apply the bounded transient transport retry policy; never wait forever after headers |
| A fully received successful response has a malformed or undecodable body | Treat it as an invalid response with one attempt. Preserve the source and checkpoint |
| Dictated text happens to look like JSON | Preserve it literally for a text response. Only unwrap a JSON response when its media type and complete single-field schema identify a transcription envelope |
| A chunk returns empty text | Fail that leaf instead of silently omitting part of the recording. Preserve earlier ordered checkpoints |
| Complete single-file recognition contains no speech | Persist a terminal no-speech failure; never leave a spinner active |
| Checkpoint write fails | Stop the attempt. Do not process later leaves that could no longer be recovered in order |
| Final terminal write fails | End the in-memory processing state, retain the best source/text available, and show a truthful storage warning |
| Process or app dies while active | On the next launch, normalize abandoned active rows to recoverable `failed`; expire overlays, live activities, keyboard handoffs, and in-memory sessions |
| Delete or Clear races active work | A platform may block the action until active work stops. If deletion is accepted, it wins: late checkpoints must not recreate the row, and startup recovery must honor the deletion intent |
| Clipboard, accessibility, paste, or target-app delivery fails | Keep `success`; the transcript stays in History and processing remains closed |
| Settings change during an attempt | The running attempt keeps its captured provider, model, language, vocabulary, and cleanup configuration; the next attempt uses the new settings |

## Bulk and chunk behavior

- Split before upload when the known safe size is exceeded.
- A server may enforce a smaller unknown limit; any rejected leaf can be split again.
- Upload leaves one at a time so text order and resource use are deterministic.
- After each successful leaf, persist the ordered merged checkpoint.
- If a later leaf fails, the recording is `failed` with that checkpoint and the original source.
- Retrying starts a new attempt for the same recording. Old attempt callbacks are ignored.

## Relaunch recovery

At startup, normalize persisted `processing` and `retrying` entries to `failed` with a plain recovery
message. Keep their audio and checkpoint text. Platform-specific in-memory spinners, overlays, live
activities, and keyboard handoff sessions must also expire or restore to a terminal state.

## Required deterministic scenarios

Each platform must cover capture-write failure, stalled finalization, permanent `4xx`, retryable
`408`/`429`/`5xx`, a disconnected successful-response body, a fully received malformed response,
repeated timeout, cancellation, initial and nested `413`, stalled native chunk export, ordered
three-chunk checkpointing, cleanup fallback, process death during processing and retry, two
simultaneous retries competing for one recording ID, retry success without duplication, delete/clear
racing a late callback, cancellation racing the first captured buffer, maximum-length capture still
entering bounded finalization, storage failure, and concurrent jobs retaining their own provider
configuration.
