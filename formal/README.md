# Formal verification

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
python3 formal/mac_audio_store_model.py --recs 1 --external-loss  # shows the open finding below
```

CI runs the first three checks in `.github/workflows/formal-verification.yml`
whenever the store, `AppState`, the contract, or this folder changes.

## What is modeled

| Swift | Model |
|---|---|
| `journal` (actor memory) and `journal.json` | `mem`, `disk`, plus `hard_disk` for the last `.hard` write |
| `Incoming/<id>.partial.m4a`, `Recordings/<id>.m4a` | `part[r]`, `fin[r]` |
| `requireWritable`, `currentRecord(for:)`, expected-stage checks, `expectedRevision` CAS | same guards, written out field by field |
| `prepare`, `markRecording`, `beginFinalization`, `checkpointClosedAudio`, `finishFinalization`, `salvageFinalizedPartial`, `beginRecognition`, `checkpointRecognition`, `markRawResultReady`, `beginCleanup`, `finishCleanup`/`useRawResult`, `markSucceeded`, `claimPendingUsage`, `fail`/`timeOut`, `tombstone`, `clearAll`, `cleanupDeletedSources` | one action each |
| `commit` | async job: CAS → before-persist hook (rename) → atomic journal write → after-persist hook (create partial); every step can fail |
| `performBoundedPersistence` deadline | caller stops waiting, store goes read-only, worker may still finish the write |
| process death, power loss | any time, including mid-commit; power loss rewinds `.ordered` writes |
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
| `EventuallyIdle` (liveness) | from every reachable state, every row can still reach a non-active stage |

`--self-test` runs eight mutants. Each one removes or reorders a single guard
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

## Results

All properties hold for the default models. Bounds: one recording with up to
three attempts and two process deaths or power losses; two concurrent
recordings with two attempts each and one fault.

### Open finding: one missing audio file makes every launch fail closed

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
