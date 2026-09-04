# Changelog

## Unreleased

- iOS keyboard keeps Quick Dictation armed after the first session so later mic taps stay in-keyboard instead of opening the app again.
- iOS keyboard no longer shows a red “couldn’t transcribe” error; failed transcriptions still save in the app and return to idle.
- iOS store init no longer bricks recording when app-group directory fsync fails after mkdir; leftover quarantine is reset once on launch.
- iOS no longer locks the app behind a failed saved-recordings check; the warning is dismissible and recording can continue.
- Overlay no longer dies on built-in mic after the 0.0.116 capture pin.
