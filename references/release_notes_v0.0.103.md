# AIDictation Release Notes

## Highlights
- The Fn/Globe dictation key no longer goes dead after a while. If you let go of Fn while another modifier was held, or if macOS quietly disabled our keyboard listener, the app could get stuck believing the key was still down — after which pressing Fn did nothing until you restarted. Both cases are fixed.

## Fixes
- Releasing the dictation key while Command, Shift, Control or Option is held now ends the recording instead of wedging the hotkey.
- A recording no longer runs forever when macOS interrupts the keyboard listener mid-hold; it now stops cleanly.
- The same interruption fix applies to every binding: key combinations, single modifier keys, and mouse buttons.

## Technical
- Hotkey decision logic extracted from the event-tap plumbing into two pure value types, `FnKeyGestureResolver` and `HotkeyGestureResolver`, following the pattern used by VoiceInk and speak2: strict matching on press, permissive on release.
- Event taps synthesize the pending release before re-enabling after `tapDisabledByTimeout` / `tapDisabledByUserInput`.
- `FnKeyMonitor` schedules its run loop source on the main run loop explicitly.
- New host-free `WhispermateTests` target (41 tests) covering all binding kinds in push-to-talk and toggle mode, run by `scripts/preflight_tests.sh` ahead of the archive in both the local release script and the release workflow.
