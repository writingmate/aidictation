# Changelog

## Unreleased

- iOS keyboard: second and later mic taps record from the background again; the record session reuses the standby audio session instead of asking iOS to reconfigure it.
- iOS keyboard: Cancel button while recording or transcribing.
- iOS keyboard: start failures show a status instead of silently returning to idle.
- iOS: cloud dictation streams via the shared Writingmate realtime client when signed in; batch upload otherwise.
- iOS keyboard keeps Quick Dictation armed after the first session so later mic taps stay in-keyboard instead of opening the app again.
- iOS keyboard no longer shows a red “couldn’t transcribe” error; failed transcriptions still save in the app and return to idle.
- iOS store init no longer bricks recording when app-group directory fsync fails after mkdir; leftover quarantine is reset once on launch.
- iOS no longer locks the app behind a failed saved-recordings check; the warning is dismissible and recording can continue.
- Overlay no longer dies on built-in mic after the 0.0.116 capture pin.
- macOS: recording falls back to the current system input when the chosen microphone is unplugged, not yet the default, or ruled out by a closed lid, instead of flashing the overlay and recording nothing. The preferred route is restored after the recording, never during it.
- macOS: a recording that cannot start says why on the overlay; clicking the callout opens Sound settings to pick another microphone.
- Account: a session restore that fails because of no network, a server error, or a keychain read miss no longer signs the user out or shows the Free plan; the last known profile stays until the backend answers. Only a server rejection of the stored session signs out.
- Account: a failed keychain read no longer deletes the stored session; signing out clears stored sessions even when none could be loaded.
