# AIDictation Release Notes

## Highlights
- The global hotkey now stays working after sleep, wake, lock, and overnight idle. Previously the hotkey could stop responding until you restarted the app.

## Fixes
- When your Mac wakes from sleep or lock, the app now recreates its event tap instead of only re-enabling it. This prevents the hotkey from going dead when macOS deregisters the tap during long sleep periods.

## Technical
- `HotkeyManager` now listens for `NSWorkspace.willSleepNotification`, `didWakeNotification`, `sessionDidBecomeActiveNotification`, and `sessionDidResignActiveNotification`. On any wake/unlock event it tears down and rebuilds the event tap from scratch if the previous tap is no longer valid or has stopped firing.
- Added a health-check timer that monitors whether the event tap is still responding. If no events arrive for an extended period while the tap should be active, the manager proactively recreates the tap rather than waiting for the next explicit wake event.
