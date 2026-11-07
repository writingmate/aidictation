#!/usr/bin/env python3
"""Exhaustive model checker for the macOS durable audio-processing store.

This is an explicit-state model checker in the style of TLC: it explores every
reachable interleaving of a finite model of the system breadth-first, checks
state invariants on every state and action properties on every transition, and
prints the shortest counterexample trace when a property fails.

Model of (source of truth):
    Whishpermate/Whispermate/Services/MacAudioProcessingStore.swift
    Whishpermate/Whispermate/Services/AppState.swift (recovery leases)
    docs/audio-processing-failure-contract.md

What is modeled
  * The actor's in-memory journal (`mem`) and journal.json (`disk`), plus the
    two managed sources per recording: Incoming/<id>.partial.m4a (`part`) and
    Recordings/<id>.m4a (`fin`).
  * Every public mutation of the store, guarded like the Swift code:
    requireWritable(), currentRecord(for:) lease fencing (clear generation,
    attempt, revision, not deleted), expected stages, and expectedRevision CAS.
  * commit() as an asynchronous job on the persistence worker: CAS against
    disk, the before-persist hook (finishFinalization's partial -> final
    rename), the atomic journal write, and the after-persist hook (prepare's
    exclusive creation of the partial). Each step can fail. The caller can hit
    its deadline while the worker keeps running; the store then fails closed.
  * Process death at any point (including mid-commit), power loss that rewinds
    `.ordered` journal writes to the last `.hard` write, and the launch path:
    validate, validateManagedSources, reconcileAfterRestart, persist, tombstone
    cleanup, and AppState's recovery pass that rebuilds a lease for every row.
  * Stale callbacks: every lease handed out during a process lifetime is kept
    and may be replayed at any time.

What is abstracted
  * Text is "present/absent"; audio integrity and file identity are one flag.
  * Deadlines are nondeterministic: a lease holder may fail/time out at any
    moment.
  * Suspending reads (inspectManagedSource, deep verification) are atomic. The
    Swift code re-checks `record == current` after each suspension and throws
    otherwise, so any interleaving there is equivalent to a no-op failure.
  * Legacy import (adoptFinalizedSource) and transient workspaces are out of
    scope.

Usage
    python3 formal/mac_audio_store_model.py            # default model
    python3 formal/mac_audio_store_model.py --self-test  # mutants must fail
    python3 formal/mac_audio_store_model.py --help
"""
from __future__ import annotations

import argparse
import itertools
import sys
import time
from collections import deque
from typing import Callable, Dict, Iterable, Iterator, List, NamedTuple, Optional, Tuple

# --------------------------------------------------------------------------
# Stages
# --------------------------------------------------------------------------
ABSENT = "absent"
PREPARING = "preparing"
RECORDING = "recording"
FINALIZING = "finalizing"
READY = "readyForRecognition"
RECOGNIZING = "recognizing"
RAW_READY = "rawResultReady"
CLEANING = "cleaning"
RESULT_READY = "resultReady"
SUCCEEDED = "succeeded"
FAILED = "failed"
DELETED = "deleted"

STAGES = (PREPARING, RECORDING, FINALIZING, READY, RECOGNIZING, RAW_READY,
          CLEANING, RESULT_READY, SUCCEEDED, FAILED, DELETED)
# Journal validation requires a complete, promoted final source for these.
PROMOTED = frozenset({READY, RECOGNIZING, RAW_READY, CLEANING, RESULT_READY, SUCCEEDED})
# Stages that keep a recording indicator or spinner visible (contract phases 0-3).
ACTIVE = frozenset({PREPARING, RECORDING, FINALIZING, READY, RECOGNIZING, RAW_READY, CLEANING})


class Rec(NamedTuple):
    stage: str = ABSENT
    att: int = 0
    rev: int = 0
    gen: int = 0
    src: str = "missing"
    integ: bool = False
    raw: bool = False
    result: bool = False
    pending: bool = False
    claimed: bool = False


NO_REC = Rec()


class Journal(NamedTuple):
    gen: int
    rev: int
    recs: Tuple[Rec, ...]


class Lease(NamedTuple):
    r: int
    att: int
    gen: int
    rev: int


class Job(NamedTuple):
    phase: str          # cas | pre | write | post | done
    r: int
    base: Journal
    proposed: Journal
    hard: bool
    pre: str            # none | rename
    post: str           # none | create
    cont: str           # none | issue | cleanup | cleanupAll | charge
    outcome: str        # pending | ok | createFailed | error | stale


class State(NamedTuple):
    mem: Journal
    disk: Journal
    hard_disk: Journal
    part: Tuple[bool, ...]
    fin: Tuple[bool, ...]
    health: str             # healthy | readOnly
    ro_cause: str           # none | timeout | storage | launch
    up: bool
    job: Optional[Job]
    waiting: bool
    leases: frozenset
    next_att: Tuple[int, ...]  # next unused attempt ID, per recording
    charges: Tuple[int, ...]   # index r * max_attempts + (att - 1)
    cleanup_q: frozenset
    fail_q: frozenset
    crashes: int


class Config(NamedTuple):
    recs: int = 2
    max_attempts: int = 3
    max_revision: int = 10**9
    max_crashes: int = 1
    external_loss: bool = False
    journal_sync_faults: bool = False
    strict_ownership: bool = False
    mutant: Optional[str] = None


# --------------------------------------------------------------------------
# Mutants: deliberately broken variants of the Swift guards. --self-test runs
# each one and requires the checker to report a violation, which shows the
# properties are strong enough to catch these bug classes.
# --------------------------------------------------------------------------
MUTANTS: Dict[str, Tuple[str, str]] = {
    "lease-ignores-revision": (
        "currentRecord(for:) no longer compares lease.revision",
        "SingleOwner",
    ),
    "fail-discards-raw-transcript": (
        "fail() during cleanup marks the row failed instead of keeping the raw result",
        "CleanupFailureKeepsResult",
    ),
    "cleanup-before-tombstone-commit": (
        "tombstone() deletes sources before its journal write returns",
        "AudioRemovedOnlyAfterTombstone",
    ),
    "journal-before-rename": (
        "finishFinalization() journals readyForRecognition before moving the partial",
        "PromotedAudioDurable",
    ),
    "launch-skips-reconcile": (
        "launch keeps active rows instead of normalizing them",
        "LaunchTerminalizes",
    ),
    "usage-sink-before-claim": (
        "claimPendingUsage() charges the account before persisting the claim",
        "NoDoubleCharge",
    ),
    "timeout-stays-writable": (
        "a commit timeout leaves the store writable while the late write can still land",
        "MemoryMatchesDisk",
    ),
    "unsynced-journal-stays-writable": (
        "persist() leaves the store writable after the journal rename's directory fsync fails",
        "MemoryMatchesDisk",
    ),
    "no-deadline-recovery": (
        "attempts cannot be failed or timed out, so stalled native work holds the row",
        "EventuallyIdle",
    ),
    "begin-recognition-ignores-source": (
        "beginRecognition() accepts a failed row without a complete final source",
        "DiskJournalValid",
    ),
}


# --------------------------------------------------------------------------
# Helpers mirroring the Swift code
# --------------------------------------------------------------------------
def source_kind(s: State, r: int) -> str:
    p, f = s.part[r], s.fin[r]
    if p and not f:
        return "partial"
    if f and not p:
        return "final"
    if p and f:
        return "both"
    return "missing"


def lease_of(r: int, x: Rec) -> Lease:
    return Lease(r, x.att, x.gen, x.rev)


def valid(j: Journal) -> bool:
    """MacAudioProcessingStore.validate(_:)

    `clearGeneration <= revision` is omitted: clearAll() bumps both, and the
    checker renames generations and revisions independently (see normalize).
    """
    for x in j.recs:
        if x.stage == ABSENT:
            continue
        if not (0 < x.rev <= j.rev) or x.gen != j.gen:
            return False
        if x.stage in PROMOTED and not (x.src == "final" and x.integ):
            return False
        if x.stage in (RAW_READY, CLEANING) and not x.raw:
            return False
        if x.stage in (RESULT_READY, SUCCEEDED) and not x.result:
            return False
        if x.pending and x.stage != SUCCEEDED:
            return False
        if x.claimed and not x.pending:
            return False
    return True


def managed_sources_known(s: State, j: Journal) -> bool:
    """validateManagedSources: every managed audio file belongs to a known row."""
    return all(j.recs[r].stage != ABSENT for r in range(len(j.recs))
               if s.part[r] or s.fin[r])


def is_current(cfg: Config, s: State, l: Lease) -> bool:
    """currentRecord(for:)"""
    x = s.mem.recs[l.r]
    if x.stage == ABSENT:
        return False
    if x.stage == DELETED:
        return False
    if l.gen != s.mem.gen or l.gen != x.gen or l.att != x.att:
        return False
    if cfg.mutant == "lease-ignores-revision":
        return True
    return l.rev == x.rev


def writable(s: State) -> bool:
    """requireWritable(): healthy and no commit in flight."""
    return s.up and s.health == "healthy" and not s.waiting and s.job is None


def bump(j: Journal, r: int, x: Rec) -> Journal:
    rev = j.rev + 1
    recs = list(j.recs)
    recs[r] = x._replace(rev=rev)
    return j._replace(rev=rev, recs=tuple(recs))


def set_tuple(t: tuple, i: int, v) -> tuple:
    lst = list(t)
    lst[i] = v
    return tuple(lst)


def start_commit(s: State, r: int, proposed: Journal, *, hard: bool = True,
                 pre: str = "none", post: str = "none", cont: str = "issue",
                 **changes) -> State:
    job = Job("cas", r, s.mem, proposed, hard, pre, post, cont, "pending")
    return s._replace(job=job, waiting=True, **changes)


# --------------------------------------------------------------------------
# Public API of the store (each yields successor states)
# --------------------------------------------------------------------------
Succ = Iterator[Tuple[str, State]]


def lease_op(cfg: Config, s: State, l: Lease, expected: Iterable[str]) -> bool:
    return writable(s) and is_current(cfg, s, l) and s.mem.recs[l.r].stage in expected


def lease_actions(cfg: Config, s: State, l: Lease) -> Succ:
    r = l.r
    x = s.mem.recs[r]

    def transition(name: str, nx: Rec, hard: bool = True) -> Tuple[str, State]:
        return (f"{name}(r{r}, lease={tuple(l)})",
                start_commit(s, r, bump(s.mem, r, nx), hard=hard))

    if lease_op(cfg, s, l, {PREPARING}):
        yield transition("markRecording", x._replace(stage=RECORDING))
    if lease_op(cfg, s, l, {RECORDING}):
        yield transition("beginFinalization", x._replace(stage=FINALIZING))
    if lease_op(cfg, s, l, {FINALIZING}):
        kind = source_kind(s, r)
        if kind in ("partial", "final") and not x.integ:
            yield transition("checkpointClosedAudio", x._replace(integ=True))
        if x.integ and kind in ("partial", "final"):
            proposed = bump(s.mem, r, x._replace(stage=READY, src="final"))
            pre = "rename" if kind == "partial" else "none"
            if cfg.mutant == "journal-before-rename":
                pre = "none"
            yield (f"finishFinalization(r{r}, lease={tuple(l)})",
                   start_commit(s, r, proposed, pre=pre))
    if lease_op(cfg, s, l, {RECOGNIZING}):
        if not x.raw:
            yield transition("checkpointRecognition", x._replace(raw=True), hard=False)
        yield transition("markRawResultReady", x._replace(stage=RAW_READY, raw=True), hard=False)
    if lease_op(cfg, s, l, {RAW_READY}):
        yield transition("beginCleanup", x._replace(stage=CLEANING), hard=False)
    if lease_op(cfg, s, l, {RAW_READY, CLEANING}) and x.raw:
        # finishCleanup and useRawResult both land in resultReady with text.
        yield transition("finishCleanup|useRawResult", x._replace(stage=RESULT_READY, result=True))
    if lease_op(cfg, s, l, {RESULT_READY}):
        yield transition("markSucceeded(usage)",
                         x._replace(stage=SUCCEEDED, pending=True, claimed=False))
        yield transition("markSucceeded(noUsage)", x._replace(stage=SUCCEEDED))
    if lease_op(cfg, s, l, set(STAGES) - {DELETED, SUCCEEDED}) \
            and cfg.mutant != "no-deadline-recovery":
        # fail(_:message:) / timeOut(_:)
        if x.stage in (RAW_READY, CLEANING) and cfg.mutant != "fail-discards-raw-transcript":
            yield transition("fail->useRawResult", x._replace(stage=RESULT_READY, result=True))
        else:
            yield transition("fail|timeOut", x._replace(stage=FAILED))


def wipe(x: Rec, gen: int) -> Rec:
    return x._replace(stage=DELETED, gen=gen, integ=False, raw=False, result=False,
                      pending=False, claimed=False)


def record_actions(cfg: Config, s: State, r: int) -> Succ:
    x = s.mem.recs[r]
    w = writable(s)

    att = s.next_att[r]
    more_att = set_tuple(s.next_att, r, att + 1)
    if w and x.stage == ABSENT and att <= cfg.max_attempts:
        nx = Rec(stage=PREPARING, att=att, gen=s.mem.gen, src="partial")
        yield (f"prepare(r{r}, att={att})",
               start_commit(s, r, bump(s.mem, r, nx), post="create", next_att=more_att))

    if w and r in s.fail_q:
        rest = s.fail_q - {r}
        if x.stage not in (ABSENT, DELETED):
            yield (f"failCurrentRecord(r{r})",
                   start_commit(s, r, bump(s.mem, r, x._replace(stage=FAILED)),
                                cont="none", fail_q=rest))
        else:
            yield (f"failCurrentRecord(r{r}) skipped", s._replace(fail_q=rest))

    if w and x.stage == FAILED and source_kind(s, r) == "partial" \
            and att <= cfg.max_attempts:
        nx = x._replace(stage=FINALIZING, att=att, integ=False)
        yield (f"salvageFinalizedPartial(r{r}, att={att})",
               start_commit(s, r, bump(s.mem, r, nx), next_att=more_att))

    source_ok = source_kind(s, r) == "final" and x.integ
    if cfg.mutant == "begin-recognition-ignores-source":
        source_ok = True
    if w and x.stage in (READY, FAILED, RESULT_READY, SUCCEEDED) and source_ok \
            and att <= cfg.max_attempts:
        nx = x._replace(stage=RECOGNIZING, att=att, gen=s.mem.gen, src="final",
                        raw=False, result=False, pending=False, claimed=False)
        yield (f"beginRecognition(r{r}, att={att})",
               start_commit(s, r, bump(s.mem, r, nx), next_att=more_att))

    if w and x.stage == SUCCEEDED and x.pending and not x.claimed:
        proposed = bump(s.mem, r, x._replace(claimed=True))
        if cfg.mutant == "usage-sink-before-claim":
            idx = r * cfg.max_attempts + (x.att - 1)
            charged = set_tuple(s.charges, idx, s.charges[idx] + 1)
            yield (f"claimPendingUsage(r{r})",
                   start_commit(s, r, proposed, cont="none", charges=charged))
        else:
            yield (f"claimPendingUsage(r{r})", start_commit(s, r, proposed, cont="charge"))

    if w and x.stage not in (ABSENT, DELETED):
        proposed = bump(s.mem, r, wipe(x, s.mem.gen))
        if cfg.mutant == "cleanup-before-tombstone-commit":
            yield (f"tombstone(r{r})",
                   start_commit(s, r, proposed, cont="none", cleanup_q=s.cleanup_q | {r}))
        else:
            yield (f"tombstone(r{r})", start_commit(s, r, proposed, cont="cleanup"))

    if w and x.stage == DELETED and r not in s.cleanup_q:
        yield (f"tombstone(r{r}) retries cleanup", s._replace(cleanup_q=s.cleanup_q | {r}))

    if s.up and r in s.cleanup_q:
        rest = s.cleanup_q - {r}
        yield (f"cleanupDeletedSources(r{r})",
               s._replace(cleanup_q=rest, part=set_tuple(s.part, r, False),
                          fin=set_tuple(s.fin, r, False)))
        yield (f"cleanupDeletedSources(r{r}) unlink failed", s._replace(cleanup_q=rest))

    if cfg.external_loss and s.fin[r]:
        yield (f"externalLoss(r{r})", s._replace(fin=set_tuple(s.fin, r, False)))


def clear_all(cfg: Config, s: State) -> Succ:
    if not writable(s):
        return
    present = [r for r, x in enumerate(s.mem.recs) if x.stage != ABSENT]
    gen = s.mem.gen + 1
    rev = s.mem.rev
    recs = list(s.mem.recs)
    for r in present:
        rev += 1
        recs[r] = wipe(recs[r], gen)._replace(rev=rev)
    if not present:
        rev += 1
    proposed = Journal(gen, rev, tuple(recs))
    yield ("clearAll", start_commit(s, 0, proposed, cont="cleanupAll"))


# --------------------------------------------------------------------------
# Persistence worker and the awaiting actor
# --------------------------------------------------------------------------
def worker_actions(cfg: Config, s: State) -> Succ:
    j = s.job
    if not s.up or j is None:
        return
    r = j.r
    if j.phase == "cas":
        if s.disk == j.base:
            yield ("worker: CAS ok", s._replace(job=j._replace(phase="pre")))
        else:
            yield ("worker: CAS stale", s._replace(job=j._replace(phase="done", outcome="stale")))
    elif j.phase == "pre":
        if j.pre == "rename":
            if s.part[r]:
                moved = s._replace(part=set_tuple(s.part, r, False), fin=set_tuple(s.fin, r, True))
                yield ("worker: rename partial->final", moved._replace(job=j._replace(phase="write")))
                yield ("worker: rename then directory fsync fails",
                       moved._replace(job=j._replace(phase="done", outcome="error")))
            yield ("worker: rename fails", s._replace(job=j._replace(phase="done", outcome="error")))
        else:
            yield ("worker: no pre-persist hook", s._replace(job=j._replace(phase="write")))
    elif j.phase == "write":
        hard_disk = j.proposed if j.hard else s.hard_disk
        yield ("worker: journal written",
               s._replace(disk=j.proposed, hard_disk=hard_disk, job=j._replace(phase="post")))
        yield ("worker: journal write fails",
               s._replace(job=j._replace(phase="done", outcome="error")))
        # persist(): the rename is visible but the directory fsync failed, so
        # its crash durability is unknown (power loss may still rewind it).
        if cfg.journal_sync_faults:
            yield ("worker: journal renamed, directory fsync fails",
                   s._replace(disk=j.proposed, job=j._replace(phase="done", outcome="uncertain")))
    elif j.phase == "post":
        if j.post == "create":
            if not s.part[r] and not s.fin[r]:
                yield ("worker: create empty partial",
                       s._replace(part=set_tuple(s.part, r, True),
                                  job=j._replace(phase="done", outcome="ok")))
            yield ("worker: create partial fails",
                   s._replace(job=j._replace(phase="done", outcome="createFailed")))
        else:
            yield ("worker: done", s._replace(job=j._replace(phase="done", outcome="ok")))
    elif j.phase == "done" and not s.waiting:
        yield ("worker: orphaned job drained", s._replace(job=None))


def caller_actions(cfg: Config, s: State) -> Succ:
    j = s.job
    if not s.up or j is None or not s.waiting:
        return
    if j.phase == "done":
        nxt = s._replace(job=None, waiting=False)
        if j.outcome in ("ok", "createFailed"):
            p = j.proposed
            leases = s.leases
            if j.cont == "issue" and j.outcome == "ok":
                leases = leases | {lease_of(j.r, p.recs[j.r])}
            fail_q = s.fail_q | {j.r} if j.outcome == "createFailed" else s.fail_q
            cleanup_q = s.cleanup_q
            if j.cont == "cleanup":
                cleanup_q = cleanup_q | {j.r}
            elif j.cont == "cleanupAll":
                cleanup_q = cleanup_q | {r for r, x in enumerate(p.recs) if x.stage == DELETED}
            charges = s.charges
            if j.cont == "charge":
                idx = j.r * cfg.max_attempts + (p.recs[j.r].att - 1)
                charges = set_tuple(charges, idx, charges[idx] + 1)
            nxt = nxt._replace(mem=p, leases=leases, fail_q=fail_q,
                               cleanup_q=cleanup_q, charges=charges)
            yield (f"commit returns {j.outcome}", nxt)
        elif j.outcome == "uncertain" and cfg.mutant != "unsynced-journal-stays-writable":
            # persist() throws .readOnly; commit() fails closed.
            yield ("commit throws (readOnly)",
                   nxt._replace(health="readOnly", ro_cause="storage"))
        else:
            yield (f"commit throws ({j.outcome})", nxt)
    else:
        # performBoundedPersistence deadline: stop waiting and fail closed. The
        # synchronous worker can still complete the write afterwards.
        if cfg.mutant == "timeout-stays-writable":
            yield ("commit times out", s._replace(waiting=False, job=None))
        else:
            yield ("commit times out", s._replace(waiting=False, health="readOnly",
                                                  ro_cause="timeout"))


# --------------------------------------------------------------------------
# Faults and launch
# --------------------------------------------------------------------------
def died(s: State, **changes) -> State:
    changes.setdefault("crashes", s.crashes + 1)
    return s._replace(up=False, job=None, waiting=False, leases=frozenset(),
                      cleanup_q=frozenset(), fail_q=frozenset(), **changes)


def fault_actions(cfg: Config, s: State) -> Succ:
    if s.up and s.health == "readOnly":
        # The store failed closed; the user quits and relaunches. This is not
        # a fault, so it does not count against the crash bound.
        yield ("user quits read-only app", died(s, crashes=s.crashes))
    if s.up and s.crashes < cfg.max_crashes:
        yield ("process dies", died(s))
        if s.disk != s.hard_disk:
            # `.ordered` writes and a rename whose directory fsync failed may be
            # lost; source file moves are always followed by directory fsyncs.
            yield ("power loss rewinds unsynced writes", died(s, disk=s.hard_disk))


def reconcile(s: State, j: Journal) -> Journal:
    """reconcileAfterRestart"""
    rev = j.rev
    recs = list(j.recs)
    for r, x in enumerate(j.recs):
        if x.stage in (ABSENT, DELETED):
            continue
        actual = source_kind(s, r)
        if x.src == actual and x.stage not in ACTIVE:
            continue
        stage = x.stage
        result = x.result
        if stage in (PREPARING, RECORDING, FINALIZING, READY, RECOGNIZING):
            stage = FAILED
        elif stage in (RAW_READY, CLEANING):
            if x.raw:
                stage, result = RESULT_READY, True
            else:
                stage = FAILED
        rev += 1
        recs[r] = x._replace(stage=stage, result=result, src=actual, rev=rev)
    return Journal(j.gen, rev, tuple(recs))


def launch(cfg: Config, s: State) -> Succ:
    if s.up:
        return
    base = s._replace(up=True, job=None, waiting=False, cleanup_q=frozenset(),
                      fail_q=frozenset())
    j = s.disk if cfg.mutant == "launch-skips-reconcile" else reconcile(s, s.disk)
    if valid(s.disk) and managed_sources_known(s, s.disk) and valid(j):
        part = tuple(False if j.recs[r].stage == DELETED else p for r, p in enumerate(s.part))
        fin = tuple(False if j.recs[r].stage == DELETED else f for r, f in enumerate(s.fin))
        # AppState's recovery pass builds a lease from every row it can see.
        leases = frozenset(lease_of(r, x) for r, x in enumerate(j.recs)
                           if x.stage not in (ABSENT, DELETED))
        # init persists (hard) only when reconciliation changed the journal.
        hard_disk = j if j != s.disk else s.hard_disk
        yield ("launch", base._replace(mem=j, disk=j, hard_disk=hard_disk, health="healthy",
                                       ro_cause="none", part=part, fin=fin, leases=leases))
    else:
        # Fail closed: change no files, expose an empty read-only store.
        yield ("launch fails closed", base._replace(
            mem=empty_journal(cfg), health="readOnly", ro_cause="launch",
            leases=frozenset()))


# --------------------------------------------------------------------------
# Transition relation
# --------------------------------------------------------------------------
def empty_journal(cfg: Config) -> Journal:
    return Journal(0, 0, tuple(NO_REC for _ in range(cfg.recs)))


def initial_state(cfg: Config) -> State:
    j = empty_journal(cfg)
    return State(mem=j, disk=j, hard_disk=j,
                 part=tuple(False for _ in range(cfg.recs)),
                 fin=tuple(False for _ in range(cfg.recs)),
                 health="healthy", ro_cause="none", up=True, job=None, waiting=False,
                 leases=frozenset(), next_att=tuple(1 for _ in range(cfg.recs)),
                 charges=tuple(0 for _ in range(cfg.recs * cfg.max_attempts)),
                 cleanup_q=frozenset(), fail_q=frozenset(), crashes=0)


def successors(cfg: Config, s: State) -> Succ:
    for l in sorted(s.leases):
        yield from lease_actions(cfg, s, l)
    for r in range(cfg.recs):
        yield from record_actions(cfg, s, r)
    yield from clear_all(cfg, s)
    yield from worker_actions(cfg, s)
    yield from caller_actions(cfg, s)
    yield from fault_actions(cfg, s)
    yield from launch(cfg, s)


def within_bounds(cfg: Config, s: State) -> bool:
    return s.mem.rev <= cfg.max_revision and s.disk.rev <= cfg.max_revision


# --------------------------------------------------------------------------
# Symmetry: recording IDs are interchangeable UUIDs.
# --------------------------------------------------------------------------
def permute_journal(j: Journal, perm: Tuple[int, ...]) -> Journal:
    return j._replace(recs=tuple(j.recs[perm[i]] for i in range(len(perm))))


def permute(cfg: Config, s: State, perm: Tuple[int, ...]) -> State:
    inv = {old: new for new, old in enumerate(perm)}

    def pj(j: Journal) -> Journal:
        return permute_journal(j, perm)

    job = s.job
    if job is not None:
        job = job._replace(r=inv[job.r], base=pj(job.base), proposed=pj(job.proposed))
    m = cfg.max_attempts
    charges = tuple(s.charges[perm[r] * m + a] for r in range(cfg.recs) for a in range(m))
    return s._replace(
        mem=pj(s.mem), disk=pj(s.disk), hard_disk=pj(s.hard_disk),
        part=tuple(s.part[perm[i]] for i in range(cfg.recs)),
        fin=tuple(s.fin[perm[i]] for i in range(cfg.recs)),
        job=job,
        leases=frozenset(l._replace(r=inv[l.r]) for l in s.leases),
        charges=charges,
        next_att=tuple(s.next_att[perm[i]] for i in range(cfg.recs)),
        cleanup_q=frozenset(inv[r] for r in s.cleanup_q),
        fail_q=frozenset(inv[r] for r in s.fail_q),
    )


def lease_is_dead(cfg: Config, s: State, l: Lease) -> bool:
    """A lease that can never pass currentRecord(for:) again in this process.

    Record revisions only grow while the process lives (RevisionsMonotone
    checks this), and leases are dropped when it dies, so a lease older than
    its record is inert forever. Under the mutant that ignores revisions the
    attempt ID plays that role instead.
    """
    x = s.mem.recs[l.r]
    if cfg.mutant == "lease-ignores-revision":
        return l.att < x.att
    return l.rev < x.rev


def normalize(cfg: Config, s: State) -> State:
    """Sound state-space reductions.

    1. Drop leases that can never be current again (lease_is_dead).
    2. Rename revisions and clear generations by order-preserving dense rank.
       The store only compares them for equality and order and only creates
       new ones as `max + 1` while nothing larger exists (MemoryMatchesDisk),
       so renaming preserves every behaviour while keeping the state space
       finite without an artificial revision bound.
    """
    leases = frozenset(l for l in s.leases if not lease_is_dead(cfg, s, l))
    journals = [s.mem, s.disk, s.hard_disk]
    if s.job is not None:
        journals += [s.job.base, s.job.proposed]
    revs = {j.rev for j in journals} | {x.rev for j in journals for x in j.recs}
    revs |= {l.rev for l in leases}
    gens = {j.gen for j in journals} | {x.gen for j in journals for x in j.recs}
    gens |= {l.gen for l in leases}
    rmap = {v: i for i, v in enumerate(sorted(revs - {0}), 1)}
    rmap[0] = 0
    gmap = {v: i for i, v in enumerate(sorted(gens))}

    def nj(j: Journal) -> Journal:
        return Journal(gmap[j.gen], rmap[j.rev],
                       tuple(x._replace(rev=rmap[x.rev], gen=gmap[x.gen])
                             if x.stage != ABSENT else x for x in j.recs))

    job = s.job
    if job is not None:
        job = job._replace(base=nj(job.base), proposed=nj(job.proposed))
    return s._replace(
        mem=nj(s.mem), disk=nj(s.disk), hard_disk=nj(s.hard_disk), job=job,
        leases=frozenset(Lease(l.r, l.att, gmap[l.gen], rmap[l.rev]) for l in leases))


def canonical(cfg: Config, s: State, perms: List[Tuple[int, ...]]) -> State:
    s = normalize(cfg, s)
    return min((permute(cfg, s, p) for p in perms), key=repr)


# --------------------------------------------------------------------------
# Properties
# --------------------------------------------------------------------------
StateInvariant = Callable[[Config, State], bool]
ActionProperty = Callable[[Config, State, str, State], bool]


def inv_mem_journal_valid(cfg: Config, s: State) -> bool:
    """Every journal the healthy store holds in memory passes validate()."""
    return not (s.up and s.health == "healthy") or valid(s.mem)


def inv_disk_journal_valid(cfg: Config, s: State) -> bool:
    """journal.json always passes validate(), so the next launch can read it."""
    return valid(s.disk)


def inv_no_orphan_audio(cfg: Config, s: State) -> bool:
    """No managed audio file exists without a durable journal row."""
    return managed_sources_known(s, s.disk)


def inv_promoted_audio_durable(cfg: Config, s: State) -> bool:
    """Contract invariant 1/7: a row promoted on disk has its final audio."""
    if cfg.external_loss:
        return True
    return all(s.fin[r] for r, x in enumerate(s.disk.recs) if x.stage in PROMOTED)


def inv_memory_matches_disk(cfg: Config, s: State) -> bool:
    """A healthy, idle store agrees with journal.json."""
    return not (s.up and s.health == "healthy" and s.job is None) or s.mem == s.disk


def inv_single_owner(cfg: Config, s: State) -> bool:
    """Contract invariant 2/8: at most one live owner per recording."""
    if not s.up:
        return True
    for r in range(cfg.recs):
        if sum(1 for l in s.leases if l.r == r and is_current(cfg, s, l)) > 1:
            return False
    return True


def inv_no_double_charge(cfg: Config, s: State) -> bool:
    """claimPendingUsage may under-report after a crash but never double-charges."""
    return all(c <= 1 for c in s.charges)


def inv_launch_never_bricked(cfg: Config, s: State) -> bool:
    """The app's own behaviour never makes a launch fail closed."""
    return s.ro_cause != "launch"


STATE_INVARIANTS: Dict[str, StateInvariant] = {
    "MemJournalValid": inv_mem_journal_valid,
    "DiskJournalValid": inv_disk_journal_valid,
    "NoOrphanAudio": inv_no_orphan_audio,
    "PromotedAudioDurable": inv_promoted_audio_durable,
    "MemoryMatchesDisk": inv_memory_matches_disk,
    "SingleOwner": inv_single_owner,
    "NoDoubleCharge": inv_no_double_charge,
    "LaunchNeverBricked": inv_launch_never_bricked,
}

ALLOWED_STEPS = {
    (ABSENT, PREPARING), (PREPARING, RECORDING), (RECORDING, FINALIZING),
    (FINALIZING, READY), (FAILED, FINALIZING), (RECOGNIZING, RAW_READY),
    (RAW_READY, CLEANING), (RAW_READY, RESULT_READY), (CLEANING, RESULT_READY),
    (RESULT_READY, SUCCEEDED),
}


def allowed_step(a: str, b: str) -> bool:
    if a == b or (a, b) in ALLOWED_STEPS:
        return True
    if b == RECOGNIZING and a in (READY, FAILED, RESULT_READY, SUCCEEDED):
        return True  # first recognition or an explicit retry
    if b == FAILED and a not in (ABSENT, DELETED, SUCCEEDED):
        return True
    if b == DELETED and a != ABSENT:
        return True
    return False


def act_disk_transitions_allowed(cfg: Config, s: State, name: str, t: State) -> bool:
    """Persisted stage changes follow the contract's state table. Power loss
    may only rewind journal.json to the last durably synced journal."""
    if name.startswith("power loss"):
        return t.disk == s.hard_disk
    return all(allowed_step(a.stage, b.stage)
               for a, b in zip(s.disk.recs, t.disk.recs))


def act_tombstone_wins(cfg: Config, s: State, name: str, t: State) -> bool:
    """If deletion is accepted, it wins: a tombstone is never resurrected.
    journal.json may lose an unsynced tombstone to power loss, but never a
    durably synced one."""
    for r in range(cfg.recs):
        if s.hard_disk.recs[r].stage == DELETED and t.disk.recs[r].stage != DELETED:
            return False
        if s.disk.recs[r].stage == DELETED and t.disk.recs[r].stage != DELETED \
                and not name.startswith("power loss"):
            return False
        if s.up and t.up and s.mem.recs[r].stage == DELETED and t.mem.recs[r].stage != DELETED:
            return False
    return True


def act_audio_removed_only_after_tombstone(cfg: Config, s: State, name: str, t: State) -> bool:
    """Never delete the only recoverable audio: removal requires a tombstone
    that is durably synced, so no crash or power loss can bring the row back
    without its audio."""
    if name.startswith("externalLoss"):
        return True
    for r in range(cfg.recs):
        lost = (s.fin[r] and not t.fin[r]) or (s.part[r] and not t.part[r] and not t.fin[r])
        if lost and t.hard_disk.recs[r].stage != DELETED:
            return False
    return True


def act_attempt_changes_only_by_new_attempt(cfg: Config, s: State, name: str, t: State) -> bool:
    """A retry keeps the recording ID; only a new attempt replaces the owner."""
    if name.startswith("power loss"):
        return True  # constrained by DiskTransitionsAllowed
    for a, b in zip(s.disk.recs, t.disk.recs):
        if a.att != b.att and a.stage != ABSENT \
                and b.stage not in (PREPARING, FINALIZING, RECOGNIZING, DELETED):
            return False
    return True


def act_launch_terminalizes(cfg: Config, s: State, name: str, t: State) -> bool:
    """A healthy relaunch never leaves a recording in an endless active state."""
    if name != "launch":
        return True
    return all(x.stage not in ACTIVE for x in t.mem.recs)


def act_success_is_never_lost(cfg: Config, s: State, name: str, t: State) -> bool:
    """Phase 5: a durable success only leaves `succeeded` for a retry or delete."""
    if name.startswith("power loss"):
        return True  # constrained by DiskTransitionsAllowed
    for a, b in zip(s.disk.recs, t.disk.recs):
        if a.stage == SUCCEEDED and b.stage not in (SUCCEEDED, RECOGNIZING, DELETED):
            return False
    return True


def act_revisions_monotone(cfg: Config, s: State, name: str, t: State) -> bool:
    """Within one process lifetime, a record's revision never goes backwards."""
    if not (s.up and t.up):
        return True
    return all(b.rev >= a.rev for a, b in zip(s.mem.recs, t.mem.recs))


def act_raw_transcript_never_lost(cfg: Config, s: State, name: str, t: State) -> bool:
    """Contract invariant 5/7: durable raw or final text is only dropped by a
    delete, by an explicit retry that starts a new attempt, or by power loss
    rewinding `.ordered` progress."""
    if name.startswith("power loss"):
        return True
    for a, b in zip(s.disk.recs, t.disk.recs):
        dropped = (a.raw and not b.raw) or (a.result and not b.result)
        if dropped and b.stage not in (DELETED, RECOGNIZING):
            return False
    return True


def act_cleanup_failure_keeps_result(cfg: Config, s: State, name: str, t: State) -> bool:
    """Phase 3: cleanup timeout/error/interruption makes raw text the result;
    it never turns recognition success into a failed row."""
    if name.startswith("power loss"):
        return True  # constrained by DiskTransitionsAllowed
    for a, b in zip(s.disk.recs, t.disk.recs):
        if a.stage in (RAW_READY, CLEANING) and b.stage == FAILED:
            return False
    return True


ACTION_PROPERTIES: Dict[str, ActionProperty] = {
    "RawTranscriptNeverLost": act_raw_transcript_never_lost,
    "CleanupFailureKeepsResult": act_cleanup_failure_keeps_result,
    "RevisionsMonotone": act_revisions_monotone,
    "DiskTransitionsAllowed": act_disk_transitions_allowed,
    "TombstoneWins": act_tombstone_wins,
    "AudioRemovedOnlyAfterTombstone": act_audio_removed_only_after_tombstone,
    "AttemptChangesOnlyByNewAttempt": act_attempt_changes_only_by_new_attempt,
    "LaunchTerminalizes": act_launch_terminalizes,
    "SuccessIsNeverLost": act_success_is_never_lost,
}


# --------------------------------------------------------------------------
# Liveness: "A timeout must return the UI to idle even when native work
# ignores cancellation." From every reachable state, every row must be able
# to reach a non-active stage using only deadline recovery: fail/timeOut on
# the attempt's own lease, the persistence worker and commit outcomes, and a
# relaunch of a store that already failed closed. Progress actions (which
# stalled native work may never perform), Delete, Clear and crashes are not
# allowed to rescue a stuck row.
# --------------------------------------------------------------------------
RECOVERY_PREFIXES = ("fail", "worker:", "commit ", "user quits read-only app", "launch")


def is_recovery_step(name: str) -> bool:
    return name.startswith(RECOVERY_PREFIXES)


def has_owner(cfg: Config, s: State, r: int) -> bool:
    """Someone in this process can still move row r: a current lease, a
    pending failCurrentRecord, or the in-flight commit."""
    return (r in s.fail_q
            or (s.job is not None and s.job.r == r)
            or any(l.r == r and is_current(cfg, s, l) for l in s.leases))


def quiescent(cfg: Config, s: State) -> bool:
    """No active row is waiting on this process. Without --strict-ownership,
    an active row nobody owns any more counts as waiting for the next launch
    (a known finding, see formal/README.md)."""
    if not (s.up and s.job is None):
        return False
    return all(x.stage not in ACTIVE or (not cfg.strict_ownership and not has_owner(cfg, s, r))
               for r, x in enumerate(s.mem.recs))


# --------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------
class Violation(NamedTuple):
    prop: str
    trace: List[Tuple[str, State]]


class Result(NamedTuple):
    states: int
    transitions: int
    seconds: float
    violation: Optional[Violation]


def check(cfg: Config, *, check_liveness: bool = True, verbose: bool = False) -> Result:
    perms = list(itertools.permutations(range(cfg.recs)))
    start = time.time()
    init = canonical(cfg, initial_state(cfg), perms)
    parent: Dict[State, Optional[Tuple[State, str]]] = {init: None}
    edges: Dict[State, List[State]] = {}   # recovery steps only
    queue = deque([init])
    transitions = 0
    next_report = 250000

    def trace_to(s: State, last: Optional[Tuple[str, State]] = None) -> List[Tuple[str, State]]:
        out: List[Tuple[str, State]] = []
        cur: Optional[State] = s
        while cur is not None:
            p = parent[cur]
            out.append((p[1] if p else "initial state", cur))
            cur = p[0] if p else None
        out.reverse()
        if last:
            out.append(last)
        return out

    def fail(prop: str, s: State, last: Optional[Tuple[str, State]] = None) -> Result:
        return Result(len(parent), transitions, time.time() - start,
                      Violation(prop, trace_to(s, last)))

    while queue:
        s = queue.popleft()
        for name, inv in STATE_INVARIANTS.items():
            if not inv(cfg, s):
                return fail(name, s)
        if not within_bounds(cfg, s):
            continue
        succ_list: List[State] = []
        for name, t in successors(cfg, s):
            transitions += 1
            for pname, prop in ACTION_PROPERTIES.items():
                if not prop(cfg, s, name, t):
                    return fail(pname, s, (name, t))
            ct = canonical(cfg, t, perms)
            if is_recovery_step(name):
                succ_list.append(ct)
            if ct not in parent:
                parent[ct] = (s, name)
                queue.append(ct)
        if check_liveness:
            edges[s] = succ_list
        if verbose and len(parent) >= next_report:
            next_report += 250000
            print(f"  ... {len(parent):,} states, queue {len(queue):,}, "
                  f"{time.time() - start:.0f}s", file=sys.stderr, flush=True)

    if check_liveness:
        # Backward reachability from quiescent states over recovery steps.
        # States cut off by the revision bound are treated as able to progress.
        reverse: Dict[State, List[State]] = {}
        for src, dsts in edges.items():
            for d in dsts:
                reverse.setdefault(d, []).append(src)
        good = {s for s in parent if quiescent(cfg, s) or s not in edges}
        frontier = deque(good)
        while frontier:
            d = frontier.popleft()
            for src in reverse.get(d, ()):
                if src not in good:
                    good.add(src)
                    frontier.append(src)
        for s in parent:
            if s not in good:
                return fail("EventuallyIdle", s)

    return Result(len(parent), transitions, time.time() - start, None)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
def describe(cfg: Config, s: State) -> str:
    rows = []
    for r in range(cfg.recs):
        m, d = s.mem.recs[r], s.disk.recs[r]
        files = "".join(("P" if s.part[r] else "-", "F" if s.fin[r] else "-"))
        rows.append(f"r{r}: mem={m.stage}/att{m.att}/rev{m.rev}"
                    f" disk={d.stage}/att{d.att}/rev{d.rev} files={files}"
                    f" integ={m.integ} raw={m.raw} result={m.result}")
    job = "none" if s.job is None else f"{s.job.phase}:{s.job.outcome}(r{s.job.r})"
    rows.append(f"up={s.up} health={s.health} waiting={s.waiting} job={job}"
                f" gen={s.mem.gen}/{s.disk.gen} leases={len(s.leases)}")
    return "\n      ".join(rows)


def print_violation(cfg: Config, v: Violation) -> None:
    print(f"VIOLATION: {v.prop}")
    for i, (name, st) in enumerate(v.trace):
        print(f"  {i:2d}. {name}\n      {describe(cfg, st)}")


def run_one(cfg: Config, label: str, *, check_liveness: bool, verbose: bool) -> Result:
    print(f"==> {label}: recs={cfg.recs} attempts={cfg.max_attempts} "
          f"crashes<={cfg.max_crashes} "
          f"externalLoss={cfg.external_loss} journalSyncFaults={cfg.journal_sync_faults}" + (f" mutant={cfg.mutant}" if cfg.mutant else ""))
    res = check(cfg, check_liveness=check_liveness, verbose=verbose)
    print(f"    {res.states:,} distinct states, {res.transitions:,} transitions, "
          f"{res.seconds:.1f}s")
    return res


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--recs", type=int, default=2)
    ap.add_argument("--max-attempts", type=int, default=3)
    ap.add_argument("--max-revision", type=int, default=10**9,
                    help="optional extra bound on raw revisions (normally unnecessary)")
    ap.add_argument("--max-crashes", type=int, default=1)
    ap.add_argument("--external-loss", action="store_true",
                    help="let something outside the app delete a final source")
    ap.add_argument("--journal-sync-faults", action="store_true",
                    help="let the journal rename land while its directory fsync fails")
    ap.add_argument("--strict-ownership", action="store_true",
                    help="do not let an ownerless active row wait for the next launch")
    ap.add_argument("--mutant", choices=sorted(MUTANTS))
    ap.add_argument("--no-liveness", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="verify every mutant is caught by the expected property")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        failures = 0
        for name, (desc, expected) in sorted(MUTANTS.items()):
            cfg = Config(recs=1, max_attempts=3, max_crashes=1, mutant=name,
                         journal_sync_faults=name == "unsynced-journal-stays-writable")
            res = run_one(cfg, f"mutant: {desc}", check_liveness=True, verbose=False)
            got = res.violation.prop if res.violation else None
            if got != expected:
                print(f"    FAIL: expected {expected}, got {got}")
                failures += 1
            else:
                print(f"    caught by {got} (trace length {len(res.violation.trace)})")
        if failures:
            print(f"self-test failed: {failures} mutant(s) not caught as expected")
            return 1
        print("self-test passed: every mutant was caught")
        return 0

    cfg = Config(recs=args.recs, max_attempts=args.max_attempts,
                 max_revision=args.max_revision, max_crashes=args.max_crashes,
                 external_loss=args.external_loss,
                 journal_sync_faults=args.journal_sync_faults,
                 strict_ownership=args.strict_ownership, mutant=args.mutant)
    res = run_one(cfg, "MacAudioProcessingStore", check_liveness=not args.no_liveness,
                  verbose=args.verbose)
    if res.violation:
        print_violation(cfg, res.violation)
        return 1
    print(f"    all {len(STATE_INVARIANTS)} invariants and {len(ACTION_PROPERTIES)} action "
          f"properties hold" + ("" if args.no_liveness else "; EventuallyIdle holds"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
