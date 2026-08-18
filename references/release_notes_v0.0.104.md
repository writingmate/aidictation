# AIDictation Release Notes

## Highlights
- Fixes a regression in 0.0.103 where dictation could stop partway through a sentence while you were still holding the key down. Please update.

## Fixes
- Removed a background check that could wrongly decide the dictation key had been let go about five seconds into a recording, cutting it off mid-sentence.

## Technical
- `FnKeyMonitor` no longer samples `NSEvent.modifierFlags` on a timer to reconcile its latch. That snapshot does not reliably report `.function` while Fn/Globe is physically held, so the reconciliation fired a spurious release on any hold longer than the 5s health-check interval. Ending an in-flight gesture is now exclusively event-driven (`tapDisabledByTimeout` / `tapDisabledByUserInput`, or monitoring stopping), matching the reference implementations.
