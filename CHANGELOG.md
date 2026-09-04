# Changelog

## Unreleased

- iOS store init no longer bricks recording when app-group directory fsync fails after mkdir; leftover quarantine is reset once on launch.
- iOS no longer locks the app behind a failed saved-recordings check; the warning is dismissible and recording can continue.
- Overlay no longer dies on built-in mic after the 0.0.116 capture pin.
