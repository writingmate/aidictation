# Changelog

## Unreleased

- macOS: dictation no longer stops working until a relaunch when the disk is slow at login or during a save; the next key press reloads saved recordings and records normally.
- macOS: a dictation right after launch no longer fails with "The previous recording is still saving"; recordings wait for the save in progress, and launch finishes past recordings in one write instead of one per recording.
- macOS: a recording interrupted before any audio was written no longer says its audio was saved, and an old recording restored to History keeps its place instead of jumping to the top.
- macOS: a recording keeps going when the microphone changes mid-recording (AirPods connecting, a mic unplugged); capture recovery now waits long enough for the new input to come up instead of giving up after half a second.
- macOS and iOS: a paid plan no longer shows as Free after a relaunch or while the keychain is locked; the last known plan stays on screen while the session restores.
- iOS keyboard: second and later mic taps record from the background again; the record session reuses the standby audio session instead of asking iOS to reconfigure it.
- iOS keyboard: Cancel button while recording or transcribing.
- iOS keyboard: start failures show a status instead of silently returning to idle.
- iOS: cloud dictation streams via the shared Writingmate realtime client when signed in; batch upload otherwise.
- iOS keyboard keeps Quick Dictation armed after the first session so later mic taps stay in-keyboard instead of opening the app again.
- iOS keyboard no longer shows a red “couldn’t transcribe” error; failed transcriptions still save in the app and return to idle.
- iOS store init no longer bricks recording when app-group directory fsync fails after mkdir; leftover quarantine is reset once on launch.
- iOS no longer locks the app behind a failed saved-recordings check; the warning is dismissible and recording can continue.
- Overlay no longer dies on built-in mic after the 0.0.116 capture pin.
