# Formal verification

Two exhaustive model checkers live here:

* `mac_audio_store_model.py`: the macOS durable audio-processing store (below).
* `android_overlay_model.py`: the Android overlay's bubble, wand and rewrite
  panel (see [Android overlay](#android-overlay)).

`mac_audio_store_model.py` is an exhaustive model checker for the macOS durable
audio-processing store (`MacAudioProcessingStore`). It enumerates **every**
reachable interleaving of a finite model of the store: callers, the
persistence worker, stale callbacks, commit timeouts, process death, power
loss, and relaunch. On every state and every transition it checks the
guarantees in [`docs/audio-processing-failure-contract.md`](../docs/audio-processing-failure-contract.md).
When a property fails it prints the shortest trace that breaks it.

It works the way TLC (the TLA+ model checker) does: explicit-state
breadth-first search with symmetry reduction. It is plain Python 3 with no
dependencies, so it runs anywhere, including CI on Linux.

```bash
python3 formal/mac_audio_store_model.py --self-test           # every seeded bug must be caught
python3 formal/mac_audio_store_model.py --recs 1 --max-crashes 2
python3 formal/mac_audio_store_model.py --recs 2 --max-attempts 2
# Each of these reproduces one open finding below:
python3 formal/mac_audio_store_model.py --recs 1 --external-loss
python3 formal/mac_audio_store_model.py --recs 1 --journal-sync-faults
python3 formal/mac_audio_store_model.py --recs 1 --strict-ownership
```

CI runs the first three checks in `.github/workflows/formal-verification.yml`
whenever the store, `AppState`, the contract, or this folder changes.

## What is modeled

| Swift | Model |
|---|---|
| `journal` (actor memory) and `journal.json` | `mem`, `disk`, plus `hard_disk` for the last durably synced write |
| `Incoming/<id>.partial.m4a`, `Recordings/<id>.m4a` | `part[r]`, `fin[r]` |
| `requireWritable`, `currentRecord(for:)`, expected-stage checks, `expectedRevision` CAS | same guards, written out field by field |
| `prepare`, `markRecording`, `beginFinalization`, `checkpointClosedAudio`, `finishFinalization`, `salvageFinalizedPartial`, `beginRecognition`, `checkpointRecognition`, `markRawResultReady`, `beginCleanup`, `finishCleanup`/`useRawResult`, `markSucceeded`, `claimPendingUsage`, `fail`/`timeOut`, `tombstone`, `clearAll`, `cleanupDeletedSources` | one action each |
| `commit` | async job: CAS → before-persist hook (rename) → atomic journal write → after-persist hook (create partial); every step can fail. With `--journal-sync-faults`, the journal rename can also land while its directory fsync fails, which `persist()` reports as `.readOnly` |
| `performBoundedPersistence` deadline | caller stops waiting, store goes read-only, worker may still finish the write |
| process death, power loss | any time, including mid-commit; power loss rewinds every write that was not durably synced |
| `init(rootDirectory:)` | validate → `validateManagedSources` → `reconcileAfterRestart` → persist → tombstone cleanup, or fail closed |
| `AppState` recovery pass | rebuilds a lease for every visible row after launch |
| late / stale callbacks | every lease handed out stays available and can be replayed |

Abstractions: text is present or absent; audio integrity and file identity
are one flag; deadlines are nondeterministic (any lease holder may fail or
time out at any moment). Reads that suspend (`inspectManagedSource`, deep
verification) are atomic. That is sound because the Swift code re-checks
`record == current` after every suspension and throws otherwise. Legacy
import (`adoptFinalizedSource`) and transient workspaces are out of scope.

Two reductions keep the search finite without cutting off behaviours, and
both are justified by properties the checker verifies:

* Leases older than their record's revision are dropped. Revisions only grow
  within a process (`RevisionsMonotone`), and leases die with the process.
* Revisions and clear generations are renamed by dense rank. The store only
  compares them for equality and order and only mints `max + 1` while nothing
  larger exists (`MemoryMatchesDisk`).

## Properties

| Property | Contract clause |
|---|---|
| `MemJournalValid`, `DiskJournalValid` | the journal always passes `validate()`, so the next launch can read it |
| `NoOrphanAudio` | `validateManagedSources` never sees unknown audio |
| `PromotedAudioDurable` | invariant 1/7: a row past finalization always has its final source on disk |
| `MemoryMatchesDisk` | never claim durability that did not happen; fail closed after an ambiguous write |
| `SingleOwner` | invariant 2/8: at most one live owner per recording |
| `NoDoubleCharge` | usage is claimed durably before the account is charged |
| `LaunchNeverBricked` | the app's own behaviour never makes a launch fail closed |
| `DiskTransitionsAllowed` | the persisted state table |
| `TombstoneWins` | "If deletion is accepted, it wins" |
| `AudioRemovedOnlyAfterTombstone` | invariant 7: never delete the only recoverable audio |
| `AttemptChangesOnlyByNewAttempt` | invariant 4: retries update the same recording ID |
| `RawTranscriptNeverLost`, `CleanupFailureKeepsResult` | invariant 5: cleanup failure keeps the raw transcript |
| `SuccessIsNeverLost` | phase 5: delivery never takes a success back |
| `LaunchTerminalizes` | invariant 3: a relaunch never shows an endless processing state |
| `RevisionsMonotone` | supports the lease reduction above |
| `EventuallyIdle` (liveness) | "A timeout must return the UI to idle even when native work ignores cancellation": from every reachable state, every row can reach a non-active stage using only `fail`/`timeOut`, commit outcomes and the relaunch of a store that already failed closed. Progress actions, Delete, Clear and crashes may not rescue it |

`--self-test` runs ten mutants. Each one removes or reorders a single guard
in the model, and the test requires the checker to catch it with the expected
property. That shows the properties can catch the bugs they are meant to:

| Mutant | Caught by |
|---|---|
| `currentRecord(for:)` ignores the lease revision | `SingleOwner` |
| `tombstone()` deletes audio before its journal write returns | `AudioRemovedOnlyAfterTombstone` |
| `finishFinalization()` journals before moving the partial | `PromotedAudioDurable` |
| launch skips `reconcileAfterRestart` | `LaunchTerminalizes` |
| usage is charged before the claim is persisted | `NoDoubleCharge` |
| a commit timeout leaves the store writable | `MemoryMatchesDisk` |
| `beginRecognition()` skips the final-source check | `DiskJournalValid` |
| `fail()` during cleanup marks the row failed | `CleanupFailureKeepsResult` |
| the store stays writable after a journal rename whose directory fsync failed | `MemoryMatchesDisk` |
| attempts cannot be failed or timed out (no deadline recovery) | `EventuallyIdle` |

## Results

All properties hold for the default models. Bounds: one recording with up to
three attempts and two process deaths or power losses; two concurrent
recordings with two attempts each and one fault.

### Open finding 1: one missing audio file makes every launch fail closed

Run with `--external-loss` (something outside the app deletes a final source,
such as a cleanup utility or disk damage). Then `LaunchNeverBricked` fails:

1. A recording reaches `succeeded` (or `resultReady`, or any promoted stage).
2. `Recordings/<id>.m4a` disappears.
3. On the next launch, `reconcileAfterRestart` sees `source != actualSource`
   and rewrites the row with `source = .missing`, keeping the stage.
4. `validate()` requires `source == .final` for that stage and throws, so
   `init` falls back to an empty read-only store. This repeats on every launch
   until someone repairs the files by hand, and every other saved recording
   becomes unavailable too.

This conflicts with contract invariant 3 ("A relaunch converts abandoned
active work to a recoverable failure"). A likely fix: in
`reconcileAfterRestart`, demote a promoted row whose final source is missing
to `failed` with `source = .missing`. Its text would be kept and a retry would
be refused. This is not applied yet, because changes to the store must pass
the Apple audio recovery matrix on macOS.

### Open finding 2: launch deletes audio on an unsynced tombstone

Run with `--journal-sync-faults`. Then `AudioRemovedOnlyAfterTombstone` fails:

1. `tombstone()` writes the deleted row and renames `journal.json`, but the
   directory fsync fails. `persist()` throws `.readOnly`, so the delete is
   reported as failed and the store fails closed.
2. The app quits or dies, and the next launch reads the visible journal.
   Reconciliation changes nothing, so `init` does not rewrite (and sync) it.
3. `init` removes the sources of every `deleted` row, including this one.
4. A power cut before anything else syncs the journal rewinds it to the old
   row. The recording comes back with its audio gone, after the user was told
   the delete failed.

This needs a failed directory fsync followed by a power cut, so it is rare.
A likely fix: sync the journal in `init` before removing tombstoned sources.
With that change (`hard_disk = j` at launch in the model), every property
holds under `--journal-sync-faults`.

### Open finding 3: a failed preparation can leave an ownerless row

Run with `--strict-ownership`. Then `EventuallyIdle` fails:

1. `prepare()` commits the `preparing` row, but creating the empty partial
   fails.
2. Its fallback `failCurrentRecord` hits a storage error that is not a
   timeout, so the store stays healthy and the row stays `preparing`.
3. `prepare()` throws without returning a lease, so nothing in this process
   can move the row. It becomes `failed` only at the next launch.

The UI is not stuck: `AppState` treats the failed `prepare()` as an idle
return. But it breaks invariant 2 ("Every active attempt has one owner … and a
terminal persisted state"). It takes two storage failures in a row. Without
`--strict-ownership`, the liveness check counts such ownerless rows as
waiting for the next launch and stays strict about everything else. A likely
fix: fail the store closed when `failCurrentRecord` cannot persist, or retry
it.

### Defense-in-depth observations

The checker also shows that some guards are redundant in a single-instance
store. That is useful to know before simplifying them:

* Removing the clear-generation comparison from `currentRecord(for:)` breaks
  nothing. `tombstone()` and `clearAll()` also bump every record's revision,
  so the revision check already makes old leases stale. The generation check
  matters only if revisions were ever left unchanged, such as with a second
  store instance on the same journal, which the `.journal.lock` CAS guards.
* A stale lease on a deleted row is blocked three ways: by the revision, by
  the `deleted` stage check, and by each operation's expected-stage check.

---

## Android overlay

`android_overlay_model.py` model-checks how
`OverlayDictationAccessibilityService` shows the four overlay windows (the
bubble, the wand, the rewrite panel and the dismiss zones) against
[`docs/android-overlay-button-states.md`](../docs/android-overlay-button-states.md).

```bash
python3 formal/android_overlay_model.py --self-test        # every seeded bug must be caught
python3 formal/android_overlay_model.py --check-findings   # each open finding still reproduces
python3 formal/android_overlay_model.py --fix all          # the proposed fixes satisfy every property
python3 formal/android_overlay_model.py                    # the current Kotlin: prints the first finding
```

### What is modeled

The service runs on the main thread, so each handler is one atomic step:

| Kotlin | Model |
|---|---|
| `windowManager.addView` / `removeView` order | the window stack, bottom to top |
| `refreshOverlayVisibility`, `shouldShowBubble`, `hasEditableDictationTarget`, `bubbleNeedsKeyboard`, `updateCommandActionsVisibility`, `shouldShowWandButton` | same rules, field by field |
| `scheduleDeferredHide`, `scheduleFocusRecoveryIfNeeded`, the shortcut's delayed tap | pending timers |
| `absorbWandButton`, `playClose`, `playApply` end actions | pending callbacks, dropped on `animate().cancel()` like `withEndAction` |
| `startRecording`, `stopRecording`, capture start/stop, delivery, `ReplaceableDeliveryFence` | the recording state, fence phase and token, and pending jobs |
| `openRewritePanel`, `runRewriteAction`, `applyRewritePanel`, `closeRewritePanel`, `dismissRewritePanel` | the rewrite session and panel |
| `updateBubbleLayoutSize` + `restackAboveBubble` | re-adding the bubble on a size change, then the wand and panel |
| `onInterrupt` | tears the overlay down until the next event |

The environment changes focus (none, editable field, password field), the
keyboard, the selection and snooze expiry, and can fail a capture or
auto-stop it on silence. The user taps the bubble, its cancel and accept
targets, the wand and the panel buttons, drags the bubble into the dismiss
area, and can use the dictation shortcut.

Pending callbacks fire in any order, which over-approximates timing. Two
timing facts are kept because ignoring them produced impossible traces:
the panel's buttons can't be hit during the 220 ms wand absorb (the panel is
still blooming from 12% scale for 460 ms), and a hide timer armed during
the absorb waits at least 250 ms, so it fires after the absorb ends.

### Properties

| Property | Doc clause |
|---|---|
| `WandNeedsBubble`, `PanelNeedsBubble` | the wand follows the bubble; the bubble hiding discards the panel |
| `Stacking` | wand invariant 5: bubble, then wand, then panel |
| `WandNotOverPanel` | wand invariant 4: never on screen with the panel, except while being absorbed |
| `DragHidesWand` | wand invariant 3: dragging to the dismiss zones hides it |
| `BubbleHiddenIffPanel` | panel invariant 8: the bubble is invisible exactly while the panel shows |
| `PanelOnlyWhenIdle` | starting dictation dismisses the panel |
| `RecordingStateMatchesFence` | the bubble shows Recording/Processing exactly while the overlay owns audio |
| `SettledBubbleVisibility` | once nothing is pending, the bubble shows exactly when the documented rule says |
| `SettledWandVisibility` | wand invariant 1: shown exactly when it can be tapped |
| `SettledNotAbsorbing` | the absorb is transient |
| `SettledDictationVisible` | a running dictation always has a visible bubble to stop it |
| `DictationSurvivesKeyboardClose` | a keyboard that hides mid-task never tears the task down |
| `EventuallySettles` (liveness) | with no further input, every timer, animation and job completes |

`--self-test` runs six mutants (absorb end leaves the wand, the wand returns
during the close animation, the panel leaves the bubble invisible,
dictation keeps the panel open, keyboard close ends dictation, sticky focus
survives the keyboard closing). Each one must be caught by the expected
property.

### Open findings in the current Kotlin

Each fix is a switch (`--fix NAME`). `--check-findings` confirms that leaving
any one out breaks its property, so the findings stay tied to the code
until it changes.

1. **The wand can disappear for the rest of the session** (`absorb`,
   `SettledNotAbsorbing`). `absorbWandButton()` clears `wandAbsorbing` only
   in `withEndAction`, and `removeCommandActionsView()` cancels the wand's
   animation, which drops that end action. Anything that removes the wand
   during the 220 ms absorb leaves the flag set, and
   `updateCommandActionsVisibility()` then returns early for good. The
   checker finds three triggers: `onInterrupt()`; a dictation shortcut tap
   that was already pending; a deferred hide armed before the wand tap
   (for example by a keyboard flap) that fires after the field lost focus.
   Fix: reset `wandAbsorbing` and the wand's scale and alpha in
   `removeCommandActionsView()`.
2. **A shortcut-started dictation can run with no bubble**
   (`start-refresh`, `SettledBubbleVisibility`). `startRecording()` sets
   `recordingState` but never refreshes visibility. Starting from the
   shortcut while the keyboard is down leaves the recording invisible until
   some other accessibility event arrives. Fix: call
   `refreshOverlayVisibility(null)` once recording starts. Related product
   decision (`--fix suppressed-start`, not required by any property): with
   the bubble snoozed, that refresh cancels the new dictation right away.
   The alternative is for the shortcut to refuse while snoozed.
3. **Dragging toward the dismiss zones loses the wand** (`drop-refresh`,
   `SettledWandVisibility`). Revealing the zones hides the wand, but a drop
   outside them only snaps the bubble, so the wand stays away until the
   selection changes. Fix: refresh visibility after the snap.
4. **A refresh during a drag brings the wand back over the zones**
   (`drag-hides-wand`, `DragHidesWand`). `updateCommandActionsVisibility()`
   doesn't know a drag is under way. Fix: keep the wand hidden while the
   dismiss zones are attached.

With all four fixes, every property holds for up to three dictations and
three panel sessions (286,480 states).

### Defense-in-depth observation

`restackAboveBubble()` never has anything to do in this model. The bubble
changes size only when the recording state changes, and at those moments the
wand and the panel are never attached (dictation dismisses both, and neither
can show while dictation runs). It is harmless insurance against future
changes.
