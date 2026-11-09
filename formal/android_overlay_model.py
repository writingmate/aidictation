#!/usr/bin/env python3
"""Exhaustive model checker for the Android dictation overlay.

Explicit-state model checking, as in mac_audio_store_model.py: every
reachable interleaving of a finite model is explored breadth-first, state
invariants are checked on every state, and the shortest counterexample is
printed when one fails.

Model of (source of truth):
    AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/
        service/OverlayDictationAccessibilityService.kt
        service/AudioWorkflowFences.kt (ReplaceableDeliveryFence)
        ui/views/OverlayRewritePanelView.kt (animation end callbacks)
    docs/android-overlay-button-states.md

What is modeled
  * The four overlay windows (bubble, wand, rewrite panel, dismiss zones), the
    order they were added to the window manager, the bubble hidden under the
    panel, and the flags the service keeps about them.
  * The service runs on the main thread, so every handler is atomic: the
    accessibility refresh, the deferred-hide timer, focus recovery, the
    shortcut start, ViewPropertyAnimator end actions (wand absorb, panel close
    and apply), and the completions of background coroutines (capture start,
    capture stop, delivery, rewrite action, apply). Pending callbacks fire in
    any order, which over-approximates real timing.
  * Cancelling an animation drops its end action, exactly like
    ViewPropertyAnimator.withEndAction.
  * The environment: focus (none, an editable field, a password field), the
    keyboard, a non-blank selection, snooze expiry, capture failure and
    auto-stop on silence. Each change raises an accessibility event.
  * The user: tapping the bubble, its cancel and accept targets, the wand and
    the panel buttons, dragging the bubble to the dismiss zones, and the
    dictation shortcut.

What is abstracted
  * Geometry, colours and text. Coalesced vs immediate refreshes and the
    250 ms / 700 ms hide delays are all "a refresh or hide is pending".
  * Microphone permission is granted; text insertion succeeds or fails.

Usage
    python3 formal/android_overlay_model.py
    python3 formal/android_overlay_model.py --self-test
"""
from __future__ import annotations

import argparse
import sys
import time
from collections import deque
from typing import Callable, Dict, Iterator, List, NamedTuple, Optional, Tuple

IDLE, RECORDING, PROCESSING = "Idle", "Recording", "Processing"
F_IDLE, F_AUDIO, F_DELIVERY = "IDLE", "AUDIO", "DELIVERY"
BUBBLE, WAND, PANEL, ZONES = "bubble", "wand", "panel", "zones"


def fx(cfg: "Cfg") -> frozenset:
    return frozenset(FIXES) if cfg.fixes is None else cfg.fixes


class Cfg(NamedTuple):
    max_dictations: int = 2
    max_sessions: int = 2
    mutant: Optional[str] = None
    # Fixes the Kotlin has. Leaving one out models the code before it (see
    # FIXES and REGRESSIONS); the default is the current code.
    fixes: Optional[frozenset] = None


class S(NamedTuple):
    # environment
    focus: str              # none | field | password
    kb: bool
    sel: bool               # the focused field has a non-blank selection
    suppressed: bool        # snoozed or hidden via the dismiss zones
    # windows, bottom to top
    stack: Tuple[str, ...]
    bubble_invisible: bool  # View.INVISIBLE + FLAG_NOT_TOUCHABLE under the panel
    # service flags
    sticky: bool            # stickyEditableFocusArmed
    absorbing: bool         # wandAbsorbing
    session: int            # rewriteSession id, 0 = none
    session_running: bool   # session.job active
    session_changed: bool   # workingText != originalText
    panel: int              # rewritePanel id, 0 = none
    rec: str                # recordingState
    fence: str              # ReplaceableDeliveryFence phase
    token: int              # fence token, 0 when idle
    lease: bool             # audioWorkflowLease != null
    stop_requested: bool    # stopRequestedDuringStart
    dragging: bool
    interrupted: bool       # onInterrupt tore the overlay down; no refresh since
    connected: bool         # the accessibility connection that owns the windows
    shortcut_waiting: bool  # a shortcut tap that arrived without a connection
    # pending main-thread callbacks and background completions
    pending: frozenset
    dictations: int
    sessions: int


def pw(pid: int) -> str:
    """Each OverlayRewritePanelView is its own window."""
    return f"{PANEL}{pid}"


def panel_windows(s: S) -> List[str]:
    return [w for w in s.stack if w.startswith(PANEL)]


def attached(s: S, w: str) -> bool:
    if w == PANEL:
        return bool(panel_windows(s))   # isRewritePanelAttached
    return w in s.stack


def add_window(s: S, w: str) -> S:
    return s._replace(stack=s.stack + (w,)) if w not in s.stack else s


def remove_window(s: S, w: str) -> S:
    return s._replace(stack=tuple(x for x in s.stack if x != w))


def add_pending(s: S, *items) -> S:
    return s._replace(pending=s.pending | frozenset(items))


def drop_pending(s: S, pred: Callable[[tuple], bool]) -> S:
    return s._replace(pending=frozenset(p for p in s.pending if not pred(p)))


def workflow(s: S) -> bool:
    return s.fence != F_IDLE


# --------------------------------------------------------------------------
# Pure functions at the top of OverlayDictationAccessibilityService.kt
# --------------------------------------------------------------------------
def can_start_selection_command(rec: str, wf: bool) -> bool:
    return rec == IDLE and not wf


def bubble_needs_keyboard(cfg: Cfg, rec: str, wf: bool, panel_open: bool) -> bool:
    if cfg.mutant == "keyboard-close-ends-dictation":
        return not panel_open
    return rec == IDLE and not wf and not panel_open


def should_show_wand(rec: str, wf: bool, has_sel: bool, panel_open: bool) -> bool:
    return has_sel and not panel_open and can_start_selection_command(rec, wf)


# --------------------------------------------------------------------------
# Service methods. Each returns the new state; all run on the main thread.
# --------------------------------------------------------------------------
def node_present(s: S) -> bool:
    return s.focus == "field"


def has_editable_target(cfg: Cfg, s: S) -> Tuple[S, bool]:
    if node_present(s):
        return s._replace(sticky=True), True
    if s.focus == "password" or (not s.kb and cfg.mutant != "sticky-survives-keyboard-close"):
        return s._replace(sticky=False), False
    return s, s.sticky


def should_show_bubble(cfg: Cfg, s: S) -> Tuple[S, bool]:
    if not s.connected:
        return s, False  # no windows and no accessibility tree without a connection
    s, target = has_editable_target(cfg, s)
    # suppressionHidesBubble: a snooze hides an idle bubble, never a running dictation.
    if not target or (s.suppressed and not (workflow(s) and "show-dictation-when-snoozed" in fx(cfg))):
        return s, False
    if not s.kb and bubble_needs_keyboard(cfg, s.rec, workflow(s), s.session != 0):
        return s, False
    return s, True


def bubble_size(rec: str) -> str:
    return "circle" if rec == IDLE else "pill"


def restack_above_bubble(cfg: Cfg, s: S) -> S:
    # Re-adds the wand, then the current panel (rewritePanel) only.
    for w in (WAND, pw(s.panel) if s.panel else None):
        if w and w in s.stack:
            s = add_window(remove_window(s, w), w)
    return s


def update_bubble_ui(cfg: Cfg, s: S, old_rec: str) -> S:
    """updateBubbleUi -> updateBubbleLayoutSize: a size change re-adds the bubble."""
    if bubble_size(old_rec) != bubble_size(s.rec) and attached(s, BUBBLE):
        s = add_window(remove_window(s, BUBBLE), BUBBLE)
        s = restack_above_bubble(cfg, s)
    return s


def set_rec(cfg: Cfg, s: S, rec: str) -> S:
    old = s.rec
    return update_bubble_ui(cfg, s._replace(rec=rec), old)


def remove_wand(cfg: Cfg, s: S) -> S:
    """removeCommandActionsView: cancels the wand's animations, which drops the
    absorb end action (ViewPropertyAnimator skips withEndAction on cancel)."""
    if not attached(s, WAND):
        return s
    s = drop_pending(s, lambda p: p[0] == "absorb_end")
    if "absorb" in fx(cfg):
        s = s._replace(absorbing=False)
    return remove_window(s, WAND)


def show_wand(cfg: Cfg, s: S) -> S:
    if not attached(s, BUBBLE):
        return s
    if attached(s, PANEL) and cfg.mutant != "wand-ignores-panel-window":
        return s
    return add_window(s, WAND)


def update_wand(cfg: Cfg, s: S) -> S:
    """updateCommandActionsVisibility"""
    if not attached(s, BUBBLE):
        return remove_wand(cfg, s)
    if s.absorbing:
        return s
    if "drag-hides-wand" in fx(cfg) and attached(s, ZONES):
        return remove_wand(cfg, s)  # fix: the wand stays hidden while dragging
    wf = workflow(s)
    panel_open = s.session != 0 or (attached(s, PANEL) and cfg.mutant != "wand-ignores-panel-window")
    has_sel = not panel_open and can_start_selection_command(s.rec, wf) and node_present(s) and s.sel
    if should_show_wand(s.rec, wf, has_sel, panel_open):
        return show_wand(cfg, s)
    return remove_wand(cfg, s)


def set_bubble_hidden_by_panel(s: S, hidden: bool) -> S:
    return s._replace(bubble_invisible=hidden)


def remove_panel(cfg: Cfg, s: S) -> S:
    """removeRewritePanel: cancelAnimations drops close/apply end actions."""
    if s.panel == 0:
        return s
    pid = s.panel
    s = drop_pending(s, lambda p: p[0] in ("close_end", "apply_end") and p[1] == pid)
    s = s._replace(panel=0)
    s = remove_window(s, pw(pid))
    if cfg.mutant != "panel-close-keeps-bubble-hidden":
        s = set_bubble_hidden_by_panel(s, False)
    return s


def dismiss_panel(cfg: Cfg, s: S) -> S:
    """dismissRewritePanel: no animation."""
    if s.session:
        sid = s.session
        s = drop_pending(s, lambda p: p[0] == "rewrite" and p[1] == sid)
    s = s._replace(session=0, session_running=False, session_changed=False)
    return remove_panel(cfg, s)


def remove_bubble(cfg: Cfg, s: S) -> S:
    if not attached(s, BUBBLE):
        return s
    s = remove_window(s, BUBBLE)
    s = dismiss_panel(cfg, s)
    return remove_wand(cfg, s)


def hide_bubble(cfg: Cfg, s: S) -> S:
    s = drop_pending(s, lambda p: p[0] == "hide")
    s = s._replace(sticky=False)
    return remove_bubble(cfg, s)


def show_bubble(cfg: Cfg, s: S) -> S:
    s = drop_pending(s, lambda p: p[0] == "hide")
    if not attached(s, BUBBLE):
        s = add_window(s, BUBBLE)
    return s


def schedule_deferred_hide(s: S) -> S:
    if not attached(s, BUBBLE) and not attached(s, WAND) and not workflow(s):
        return s
    if any(p[0] == "hide" for p in s.pending):
        return s
    # ("hide", early): early means armed before the current wand absorb began.
    return add_pending(s, ("hide", False))


def refresh(cfg: Cfg, s: S) -> S:
    """refreshOverlayVisibility(null) + scheduleFocusRecoveryIfNeeded()"""
    if not s.connected:
        return s
    s = s._replace(interrupted=False)
    s, show = should_show_bubble(cfg, s)
    if show:
        s = show_bubble(cfg, s)
        s = update_wand(cfg, s)
    else:
        s = schedule_deferred_hide(s)
    return schedule_focus_recovery(cfg, s)


RECOVERY_ATTEMPTS = 3


def schedule_focus_recovery(cfg: Cfg, s: S, force: bool = False) -> S:
    if (not force and not s.sticky) or attached(s, BUBBLE) or s.suppressed:
        return s
    if any(p[0] == "recovery" for p in s.pending):
        return s
    # FOCUS_RECOVERY_ATTEMPTS is 15; any bound keeps the same behaviours.
    return add_pending(s, ("recovery", RECOVERY_ATTEMPTS))


def reset_after_recording(cfg: Cfg, s: S, token: int) -> S:
    if s.fence == F_IDLE or s.token != token:
        return s
    s = s._replace(fence=F_IDLE, token=0, lease=False)
    s = drop_pending(s, lambda p: p[0] in ("start", "stop", "deliver"))
    s = set_rec(cfg, s, IDLE)
    return refresh(cfg, s)


def cancel_overlay_audio(cfg: Cfg, s: S) -> S:
    if s.fence == F_IDLE:
        return s
    return reset_after_recording(cfg, s, s.token)


def start_recording(cfg: Cfg, s: S) -> Optional[S]:
    if s.rec != IDLE:
        return None
    if cfg.mutant != "dictation-keeps-panel":
        s = dismiss_panel(cfg, s)
    s = remove_wand(cfg, s)
    if not node_present(s) and not s.sticky:
        return s  # "Focus a text field first"
    if s.dictations >= cfg.max_dictations:
        return None  # bound of the model, not of the app
    # cancelDeliveryForReplacement: the old delivery's finally is fenced out.
    s = drop_pending(s, lambda p: p[0] == "deliver")
    token = s.dictations + 1
    s = s._replace(fence=F_AUDIO, token=token, lease=False, stop_requested=False,
                   dictations=s.dictations + 1)
    s = set_rec(cfg, s, RECORDING)
    s = add_pending(s, ("start", token))
    if "start-refresh" in fx(cfg):
        s = refresh(cfg, s)  # fix: show the bubble for the dictation just started
    return s


def stop_recording(cfg: Cfg, s: S, discard: bool) -> S:
    if s.rec != RECORDING or s.fence != F_AUDIO:
        return s
    token = s.token
    if not s.lease:
        s = s._replace(stop_requested=True)
        if discard:
            s = drop_pending(s, lambda p: p[0] == "start")
            s = reset_after_recording(cfg, s, token)
        return s
    if discard:
        return reset_after_recording(cfg, s, token)
    s = set_rec(cfg, s, PROCESSING)
    return add_pending(s, ("stop", token))


def on_bubble_tapped(cfg: Cfg, s: S) -> Optional[S]:
    s = remove_window(s, ZONES)._replace(dragging=False)
    if s.rec == IDLE:
        return start_recording(cfg, s)
    if s.rec == RECORDING:
        return stop_recording(cfg, s, False)
    return s


def open_panel(cfg: Cfg, s: S) -> Optional[S]:
    if s.session != 0 or not attached(s, BUBBLE):
        return s
    if "open-guards-panel-window" in fx(cfg) and attached(s, PANEL):
        return s  # fix: never open over a panel that is still withering
    if not can_start_selection_command(s.rec, workflow(s)):
        return s
    if not (node_present(s) and s.sel):
        return remove_wand(cfg, s)
    if s.sessions >= cfg.max_sessions:
        return None
    sid = s.sessions + 1
    s = s._replace(session=sid, session_running=False, session_changed=False,
                   panel=sid, sessions=sid)
    s = add_window(s, pw(sid))
    s = set_bubble_hidden_by_panel(s, True)
    # absorbWandButton
    if not attached(s, WAND):
        return remove_wand(cfg, s)
    s = drop_pending(s, lambda p: p[0] == "absorb_end")
    # A hide timer already running may fire during the absorb; one armed from
    # now on waits at least 250 ms, longer than the 220 ms absorb.
    early = frozenset(("hide", True) if p[0] == "hide" else p for p in s.pending)
    return add_pending(s._replace(absorbing=True, pending=early), ("absorb_end",))


def close_panel(cfg: Cfg, s: S) -> S:
    if s.session == 0:
        return s
    sid = s.session
    s = drop_pending(s, lambda p: p[0] == "rewrite" and p[1] == sid)
    s = s._replace(session=0, session_running=False, session_changed=False)
    if s.panel == 0 or not attached(s, PANEL):
        s = remove_panel(cfg, s)
        return refresh(cfg, s)
    return add_pending(s, ("close_end", s.panel))


def apply_panel(cfg: Cfg, s: S) -> S:
    if s.session == 0 or s.panel == 0 or s.session_running:
        return s
    if not s.session_changed:
        return close_panel(cfg, s)
    sid = s.session
    s = s._replace(session=0, session_running=False, session_changed=False)
    if attached(s, PANEL):
        s = add_pending(s, ("apply_end", s.panel))
    else:
        s = remove_panel(cfg, s)
    return add_pending(s, ("apply_job", sid))


def connection_ends(cfg: Cfg, s: S) -> S:
    """onUnbind. The system removes the connection's windows with it."""
    s = s._replace(connected=False, shortcut_waiting=False, stack=(), bubble_invisible=False,
                   dragging=False)
    if "unbind-tears-down" not in fx(cfg):
        return s  # the service kept its flags and its dictation
    # tearDownOverlay: ends the dictation and cancels the connection's work. The apply
    # job is not the connection's; its refresh is a no-op until the next connection.
    s = drop_pending(s, lambda p: p[0] != "apply_job")
    return s._replace(fence=F_IDLE, token=0, lease=False, stop_requested=False, rec=IDLE,
                      absorbing=False, session=0, session_running=False,
                      session_changed=False, panel=0, sticky=False)


def connection_starts(cfg: Cfg, s: S) -> S:
    """onServiceConnected, then a shortcut tap that waited for it."""
    waiting = s.shortcut_waiting
    s = s._replace(connected=True, shortcut_waiting=False)
    s = schedule_focus_recovery(cfg, refresh(cfg, s), force=True)
    return add_pending(s, ("shortcut",)) if waiting else s


# --------------------------------------------------------------------------
# Transition relation
# --------------------------------------------------------------------------
Succ = Iterator[Tuple[str, S]]


def env_actions(cfg: Cfg, s: S) -> Succ:
    def changed(name: str, t: S) -> Tuple[str, S]:
        return name, add_pending(t, ("refresh",))

    for focus in ("none", "field", "password"):
        if focus != s.focus:
            yield changed(f"env: focus -> {focus}", s._replace(focus=focus, sel=False))
    yield changed(f"env: keyboard {'hides' if s.kb else 'shows'}", s._replace(kb=not s.kb))
    if s.focus == "field":
        yield changed(f"env: selection {'cleared' if s.sel else 'made'}", s._replace(sel=not s.sel))
    if s.suppressed:
        yield changed("env: snooze expires", s._replace(suppressed=False))
    if s.rec == RECORDING and s.lease:
        # coordinator failureEvents
        yield "env: capture fails", reset_after_recording(cfg, s, s.token)
        # auto-stop on silence
        yield "env: silence auto-stop", stop_recording(cfg, s, False)
    if not s.connected:
        if not s.shortcut_waiting:
            yield "env: dictation shortcut", s._replace(shortcut_waiting=True)
    elif not any(p[0] == "shortcut" for p in s.pending):
        yield "env: dictation shortcut", add_pending(s, ("shortcut",))
    if s.connected:
        yield "env: accessibility connection ends", connection_ends(cfg, s)
    else:
        yield "env: accessibility connection starts", connection_starts(cfg, s)
    # onInterrupt
    if "interrupt-keeps-overlay" in fx(cfg):
        yield "env: onInterrupt", s
    else:
        t = cancel_overlay_audio(cfg, s)
        t = dismiss_panel(cfg, t)
        t = hide_bubble(cfg, t)
        t = remove_wand(cfg, t)
        t = remove_window(t, ZONES)._replace(dragging=False)
        t = drop_pending(t, lambda p: p[0] in ("refresh", "recovery"))
        yield "env: onInterrupt", t._replace(interrupted=True)


def user_actions(cfg: Cfg, s: S) -> Succ:
    touchable = attached(s, BUBBLE) and not s.bubble_invisible
    if touchable and not s.dragging:
        t = on_bubble_tapped(cfg, s)
        if t is not None:
            yield "user: tap bubble", t
        if s.rec == RECORDING:
            yield "user: tap cancel (X)", stop_recording(cfg, s, True)
            yield "user: tap accept (check)", stop_recording(cfg, s, False)
        # shouldRevealDismissZones -> showDismissActions hides the wand, adds the zones
        t = remove_wand(cfg, s)
        yield "user: drag bubble into the dismiss area", add_window(t, ZONES)._replace(dragging=True)
    if s.dragging:
        base = remove_window(s, ZONES)._replace(dragging=False)
        if "drop-refresh" in fx(cfg):
            yield "user: drop bubble outside the zones", refresh(cfg, base)
        else:
            yield "user: drop bubble outside the zones", base
        if attached(s, BUBBLE):
            t = base._replace(suppressed=True)   # snoozeBubble / hideBubblePermanently
            t = cancel_overlay_audio(cfg, t)
            t = hide_bubble(cfg, t)
            yield "user: drop bubble on a dismiss zone", remove_wand(cfg, t)
    if attached(s, WAND) and not s.dragging:
        t = open_panel(cfg, s)
        if t is not None:
            yield "user: tap wand", t
    # The panel's buttons are touchable while it blooms, even during the absorb.
    if s.session and attached(s, PANEL) and not s.dragging:
        if not s.session_running:
            yield "user: panel action", add_pending(
                s._replace(session_running=True), ("rewrite", s.session))
            yield "user: panel apply", apply_panel(cfg, s)
        yield "user: panel close", close_panel(cfg, s)


def system_actions(cfg: Cfg, s: S) -> Succ:
    for p in sorted(s.pending):
        rest = s._replace(pending=s.pending - {p})
        kind = p[0]
        if kind == "refresh":
            yield "event: accessibility refresh", refresh(cfg, rest)
        elif kind == "hide":
            if rest.absorbing and not p[1]:
                continue  # timing: cannot fire before the absorb ends
            t, show = should_show_bubble(cfg, rest)
            if show:
                yield "timer: deferred hide finds bubble wanted", show_bubble(cfg, t)
            else:
                t = cancel_overlay_audio(cfg, t)
                t = hide_bubble(cfg, t)
                yield "timer: deferred hide", remove_wand(cfg, t)
        elif kind == "recovery":
            if attached(rest, BUBBLE) or rest.suppressed:
                yield "timer: focus recovery ends", rest
                continue
            t, show = should_show_bubble(cfg, rest)
            if show:
                yield "timer: focus recovery refreshes", refresh(cfg, t)
            else:
                if p[1] > 1:
                    yield "timer: focus recovery retries", add_pending(t, ("recovery", p[1] - 1))
                else:
                    yield "timer: focus recovery gives up", t
        elif kind == "shortcut":
            if not rest.connected:
                yield "timer: shortcut finds no connection", rest
                continue
            t = on_bubble_tapped(cfg, rest)
            # Past the model's dictation bound the tap drains as a no-op.
            yield "timer: shortcut taps bubble", t if t is not None else rest
        elif kind == "absorb_end":
            t = rest._replace(absorbing=False)
            if cfg.mutant == "absorb-end-keeps-wand":
                pass
            elif "absorb-end-refresh" in fx(cfg):
                t = update_wand(cfg, t)  # fix: re-evaluate instead of hiding
            else:
                t = remove_wand(cfg, t)
            yield "anim: wand absorb ends", t
        elif kind in ("close_end", "apply_end"):
            # The end action calls removeRewritePanel(), which removes whatever
            # panel is current, with no check that it is this one.
            what = "close" if kind == "close_end" else "apply"
            yield f"anim: panel {what} ends", refresh(cfg, remove_panel(cfg, rest))
        elif kind == "apply_job":
            yield "job: apply finishes", refresh(cfg, rest)
        elif kind == "rewrite":
            if p[1] == rest.session:
                t = rest._replace(session_running=False)
                yield "job: rewrite succeeds", t._replace(session_changed=True)
                yield "job: rewrite fails", t
        elif kind == "start":
            token = p[1]
            if rest.fence != F_AUDIO or rest.token != token:
                yield "job: stale capture start", rest
                continue
            yield "job: capture fails to start", reset_after_recording(cfg, rest, token)
            t = rest._replace(lease=True)
            if t.stop_requested:
                t = stop_recording(cfg, t._replace(stop_requested=False), False)
            yield "job: capture started", t
        elif kind == "stop":
            token = p[1]
            if rest.fence != F_AUDIO or rest.token != token:
                yield "job: stale capture stop", rest
                continue
            yield "job: no speech / finalize failed", reset_after_recording(cfg, rest, token)
            # beginDeliveryPhase
            t = rest._replace(fence=F_DELIVERY)
            t = set_rec(cfg, t, IDLE)
            t = refresh(cfg, t)
            yield "job: capture stopped, delivering", add_pending(t, ("deliver", token))
        elif kind == "deliver":
            yield "job: delivery finishes", reset_after_recording(cfg, rest, p[1])


def successors(cfg: Cfg, s: S) -> Succ:
    yield from env_actions(cfg, s)
    yield from user_actions(cfg, s)
    yield from system_actions(cfg, s)


def is_system_step(name: str) -> bool:
    return name.split(":")[0] in ("event", "timer", "anim", "job")


def initial(cfg: Cfg) -> S:
    s = S(focus="none", kb=False, sel=False, suppressed=False, stack=(),
          bubble_invisible=False, sticky=False, absorbing=False, session=0,
          session_running=False, session_changed=False, panel=0, rec=IDLE,
          fence=F_IDLE, token=0, lease=False, stop_requested=False,
          dragging=False, interrupted=False, connected=True, shortcut_waiting=False,
          pending=frozenset(), dictations=0, sessions=0)
    # onServiceConnected
    return schedule_focus_recovery(cfg, refresh(cfg, s), force=True)


# --------------------------------------------------------------------------
# Properties
# --------------------------------------------------------------------------
def order_ok(s: S) -> bool:
    idx = {w: i for i, w in enumerate(s.stack)}
    panels = [idx[w] for w in panel_windows(s)]
    if WAND in idx and idx[WAND] < idx[BUBBLE]:
        return False
    if panels and min(panels) < idx[BUBBLE]:
        return False
    if WAND in idx and panels and idx[WAND] > min(panels):
        return False
    return True


def inv_single_panel(cfg: Cfg, s: S) -> bool:
    """One rewrite panel window at a time, and it is the one the service tracks."""
    panels = panel_windows(s)
    return len(panels) <= 1 and (not panels or panels[0] == pw(s.panel))


def inv_wand_needs_bubble(cfg: Cfg, s: S) -> bool:
    """Invariant 3: the wand follows the bubble."""
    return not attached(s, WAND) or attached(s, BUBBLE)


def inv_panel_needs_bubble(cfg: Cfg, s: S) -> bool:
    """Panel invariant 8: the field losing focus (bubble hides) discards the panel."""
    return not attached(s, PANEL) or attached(s, BUBBLE)


def inv_stacking(cfg: Cfg, s: S) -> bool:
    """Wand invariant 5: always below the panel, above the bubble."""
    return order_ok(s)


def inv_wand_not_over_panel(cfg: Cfg, s: S) -> bool:
    """Wand invariant 4: never on screen with the panel except while absorbed."""
    return not (attached(s, WAND) and attached(s, PANEL)) or s.absorbing


def inv_bubble_hidden_iff_panel(cfg: Cfg, s: S) -> bool:
    """Panel invariant 8: hidden exactly while the panel is on screen."""
    return s.bubble_invisible == attached(s, PANEL)


def inv_panel_only_when_idle(cfg: Cfg, s: S) -> bool:
    """Starting dictation dismisses the panel; it opens only from an idle bubble."""
    return not attached(s, PANEL) or (s.rec == IDLE and s.fence == F_IDLE)


def inv_recording_state_matches_fence(cfg: Cfg, s: S) -> bool:
    """The bubble shows Recording/Processing exactly while the overlay owns audio."""
    return (s.rec == IDLE) == (s.fence != F_AUDIO)


def inv_drag_hides_wand(cfg: Cfg, s: S) -> bool:
    """Wand invariant 3: dragging the bubble to the dismiss zones hides it."""
    return not (attached(s, ZONES) and attached(s, WAND))


def settled(s: S) -> bool:
    """Nothing is pending. After onInterrupt the overlay intentionally stays
    down until the next accessibility event, so that is not settled either."""
    return not s.pending and not s.dragging and not s.interrupted


def expected_bubble(cfg: Cfg, s: S) -> bool:
    _, show = should_show_bubble(Cfg(), s)   # the documented rule, never mutated
    return show


def inv_settled_bubble(cfg: Cfg, s: S) -> bool:
    """Visibility: once nothing is pending, the bubble shows exactly when the
    documented rule says so (focused editable field, keyboard up unless
    dictation or the panel is under way, not snoozed or hidden)."""
    return not settled(s) or attached(s, BUBBLE) == expected_bubble(cfg, s)


def inv_settled_wand(cfg: Cfg, s: S) -> bool:
    """Wand invariant 1: shown exactly when it can be tapped."""
    if not settled(s):
        return True
    panel_open = s.session != 0 or attached(s, PANEL)
    want = attached(s, BUBBLE) and should_show_wand(
        s.rec, workflow(s), node_present(s) and s.sel, panel_open)
    return attached(s, WAND) == want


def inv_settled_not_absorbing(cfg: Cfg, s: S) -> bool:
    """The absorb is a transient: nothing pending means it has finished."""
    return not settled(s) or not s.absorbing


def inv_settled_dictation_visible(cfg: Cfg, s: S) -> bool:
    """A running dictation always has a visible bubble to stop it with."""
    return not settled(s) or s.rec == IDLE or (attached(s, BUBBLE) and not s.bubble_invisible)


def act_dictation_survives_keyboard_close(cfg: Cfg, s: S, name: str, t: S) -> bool:
    """A keyboard that hides mid-task never tears the task down, and neither
    does a snooze: the deferred hide may cancel a dictation only when its field
    is gone, never while the field still has focus. (Dropping the bubble on a
    dismiss zone ends dictation on purpose; that is a separate path.)"""
    if name != "timer: deferred hide":
        return True
    return not (workflow(s) and node_present(s))


def act_interrupt_keeps_overlay(cfg: Cfg, s: S, name: str, t: S) -> bool:
    """An interrupt asks for spoken feedback to stop. The overlay gives none, and any
    app can send one, so it never ends a dictation or takes the bubble away."""
    if name != "env: onInterrupt":
        return True
    return not (workflow(s) and not workflow(t)) and (not attached(s, BUBBLE) or attached(t, BUBBLE))


def inv_no_dictation_while_disconnected(cfg: Cfg, s: S) -> bool:
    """Without its connection the overlay has no windows, so no dictation runs that
    nothing on screen could stop."""
    return s.connected or (not workflow(s) and s.rec == IDLE and not s.stack)


ACTION_PROPERTIES: Dict[str, Callable[[Cfg, S, str, S], bool]] = {
    "DictationSurvivesKeyboardClose": act_dictation_survives_keyboard_close,
    "InterruptKeepsOverlay": act_interrupt_keeps_overlay,
}


INVARIANTS: Dict[str, Callable[[Cfg, S], bool]] = {
    "WandNeedsBubble": inv_wand_needs_bubble,
    "PanelNeedsBubble": inv_panel_needs_bubble,
    "Stacking": inv_stacking,
    "SinglePanel": inv_single_panel,
    "DragHidesWand": inv_drag_hides_wand,
    "WandNotOverPanel": inv_wand_not_over_panel,
    "BubbleHiddenIffPanel": inv_bubble_hidden_iff_panel,
    "PanelOnlyWhenIdle": inv_panel_only_when_idle,
    "RecordingStateMatchesFence": inv_recording_state_matches_fence,
    "SettledBubbleVisibility": inv_settled_bubble,
    "SettledWandVisibility": inv_settled_wand,
    "SettledNotAbsorbing": inv_settled_not_absorbing,
    "SettledDictationVisible": inv_settled_dictation_visible,
    "NoDictationWhileDisconnected": inv_no_dictation_while_disconnected,
}


FIXES: Dict[str, str] = {
    "absorb": "removeCommandActionsView also clears wandAbsorbing and resets the wand",
    "start-refresh": "startRecording refreshes overlay visibility once it is recording",
    "show-dictation-when-snoozed": "suppressionHidesBubble: a snooze never hides a running dictation",
    "drop-refresh": "dropping the bubble outside the zones re-evaluates the wand",
    "drag-hides-wand": "updateCommandActionsVisibility keeps the wand hidden while the zones show",
    "absorb-end-refresh": "the absorb end action re-evaluates the wand instead of hiding it",
    "open-guards-panel-window": "openRewritePanel also refuses while a panel window is attached",
    "interrupt-keeps-overlay": "onInterrupt leaves the bubble and a running dictation alone",
    "unbind-tears-down": "onUnbind ends the dictation and forgets the windows the connection took",
}

# Regression guard: reverting any one fix must bring its bug back.
REGRESSIONS: Dict[str, str] = {
    "absorb": "SettledWandVisibility",
    "start-refresh": "SettledBubbleVisibility",
    "drop-refresh": "SettledWandVisibility",
    "drag-hides-wand": "DragHidesWand",
    "absorb-end-refresh": "SettledWandVisibility",
    "open-guards-panel-window": "SinglePanel",
    "show-dictation-when-snoozed": "DictationSurvivesKeyboardClose",
    "interrupt-keeps-overlay": "InterruptKeepsOverlay",
    "unbind-tears-down": "NoDictationWhileDisconnected",
}

MUTANTS: Dict[str, Tuple[str, str]] = {
    "absorb-end-keeps-wand": ("the absorb end action leaves the wand window on screen",
                              "WandNotOverPanel"),
    "wand-ignores-panel-window": ("the wand returns while the panel's close animation runs",
                                  "WandNotOverPanel"),
    "panel-close-keeps-bubble-hidden": ("removing the panel leaves the bubble invisible",
                                        "BubbleHiddenIffPanel"),
    "dictation-keeps-panel": ("starting dictation leaves the panel open", "PanelOnlyWhenIdle"),
    "keyboard-close-ends-dictation": ("bubbleNeedsKeyboard ignores a running dictation",
                                      "DictationSurvivesKeyboardClose"),
    "sticky-survives-keyboard-close": ("sticky focus survives the keyboard closing",
                                       "SettledBubbleVisibility"),
}


# --------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------
class Result(NamedTuple):
    states: int
    transitions: int
    seconds: float
    violation: Optional[Tuple[str, List[Tuple[str, S]]]]


def check(cfg: Cfg) -> Result:
    start = time.time()
    init = initial(cfg)
    parent: Dict[S, Optional[Tuple[S, str]]] = {init: None}
    sys_edges: Dict[S, List[S]] = {}
    queue = deque([init])
    transitions = 0

    def trace(s: S) -> List[Tuple[str, S]]:
        out = []
        cur: Optional[S] = s
        while cur is not None:
            p = parent[cur]
            out.append((p[1] if p else "service connected", cur))
            cur = p[0] if p else None
        return out[::-1]

    def fail(name: str, s: S) -> Result:
        return Result(len(parent), transitions, time.time() - start, (name, trace(s)))

    while queue:
        s = queue.popleft()
        for name, inv in INVARIANTS.items():
            if not inv(cfg, s):
                return fail(name, s)
        out: List[S] = []
        for name, t in successors(cfg, s):
            transitions += 1
            for pname, prop in ACTION_PROPERTIES.items():
                if not prop(cfg, s, name, t):
                    if t not in parent:
                        parent[t] = (s, name)
                    return fail(pname, t)
            if is_system_step(name):
                out.append(t)
            if t not in parent:
                parent[t] = (s, name)
                queue.append(t)
        sys_edges[s] = out

    # Liveness (AlwaysSettles): with no further input from the user or the
    # environment, every run of timers, animation ends and job completions
    # terminates, and it terminates settled. Checked as: (1) every state with
    # pending work has a system step, (2) system steps between states with
    # pending work form no cycle, so no run goes on forever, and (3) a state
    # with nothing pending is never mid-absorb. A held drag or an interrupted
    # overlay waits on the user or the next event, so they may end a run.
    for st, outs in sys_edges.items():
        if st.pending and not outs:
            return fail("AlwaysSettles", st)
        if not st.pending and st.absorbing:
            return fail("AlwaysSettles", st)
    WHITE, GREY, BLACK = 0, 1, 2
    colour: Dict[S, int] = {}
    for root in sys_edges:
        if colour.get(root, WHITE) != WHITE or not root.pending:
            continue
        stack = [(root, iter(sys_edges.get(root, ())))]
        colour[root] = GREY
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                colour[node] = BLACK
                stack.pop()
                continue
            if not nxt.pending:
                continue
            c = colour.get(nxt, WHITE)
            if c == GREY:
                return fail("AlwaysSettles", nxt)
            if c == WHITE:
                colour[nxt] = GREY
                stack.append((nxt, iter(sys_edges.get(nxt, ()))))
    return Result(len(parent), transitions, time.time() - start, None)


def describe(s: S) -> str:
    pend = ",".join(sorted("/".join(map(str, p)) for p in s.pending)) or "-"
    return (f"windows=[{' < '.join(s.stack) or '-'}] focus={s.focus} kb={s.kb} sel={s.sel} "
            f"rec={s.rec} fence={s.fence} session={s.session} panel={s.panel} "
            f"absorbing={s.absorbing} hiddenByPanel={s.bubble_invisible} "
            f"suppressed={s.suppressed} sticky={s.sticky} connected={s.connected} pending={pend}")


def run(cfg: Cfg, label: str) -> Result:
    print(f"==> {label}: dictations<={cfg.max_dictations} panels<={cfg.max_sessions}"
          + (f" reverted={','.join(sorted(set(FIXES) - fx(cfg)))}" if fx(cfg) != set(FIXES) else "")
          + (f" mutant={cfg.mutant}" if cfg.mutant else ""))
    res = check(cfg)
    print(f"    {res.states:,} distinct states, {res.transitions:,} transitions, {res.seconds:.1f}s")
    return res


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--max-dictations", type=int, default=2)
    ap.add_argument("--max-panels", type=int, default=2)
    ap.add_argument("--revert", action="append", default=[], choices=sorted(FIXES) + ["all"],
                    help="model the code without a fix (repeatable; 'all' for the pre-fix code)")
    ap.add_argument("--mutant", choices=sorted(MUTANTS))
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--check-regressions", action="store_true",
                    help="reverting any one fix must bring its bug back")
    args = ap.parse_args(argv)

    if args.self_test:
        bad = 0
        for name, (desc, expected) in sorted(MUTANTS.items()):
            res = run(Cfg(max_dictations=1, max_sessions=1, mutant=name),
                      f"mutant: {desc}")
            got = res.violation[0] if res.violation else None
            if got == expected:
                print(f"    caught by {got} (trace length {len(res.violation[1])})")
            else:
                print(f"    FAIL: expected {expected}, got {got}")
                bad += 1
        print("self-test passed: every mutant was caught" if not bad
              else f"self-test failed: {bad} mutant(s) not caught as expected")
        return 1 if bad else 0

    if args.check_regressions:
        bad = 0
        for fix, expected in sorted(REGRESSIONS.items()):
            fixes = frozenset(FIXES) - {fix}
            res = run(Cfg(max_dictations=1, max_sessions=2, fixes=fixes), f"without fix {fix}")
            got = res.violation[0] if res.violation else None
            if got == expected:
                print(f"    bug returns as {got} (trace length {len(res.violation[1])})")
            else:
                print(f"    FAIL: expected {expected}, got {got}")
                bad += 1
        res = run(Cfg(max_dictations=1, max_sessions=2, fixes=frozenset()), "code before the fixes")
        if res.violation is None:
            print("    FAIL: the pre-fix code is expected to fail")
            bad += 1
        else:
            print(f"    fails as expected ({res.violation[0]})")
        print("regression check passed" if not bad else f"regression check failed: {bad}")
        return 1 if bad else 0

    cfg = Cfg(max_dictations=args.max_dictations, max_sessions=args.max_panels,
              mutant=args.mutant,
              fixes=frozenset() if "all" in args.revert else frozenset(FIXES) - set(args.revert))
    res = run(cfg, "Android overlay")
    if res.violation:
        name, tr = res.violation
        print(f"VIOLATION: {name}")
        for i, (step, st) in enumerate(tr):
            print(f"  {i:2d}. {step}\n      {describe(st)}")
        return 1
    print(f"    all {len(INVARIANTS)} invariants and {len(ACTION_PROPERTIES)} action "
          f"property hold; AlwaysSettles holds")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
