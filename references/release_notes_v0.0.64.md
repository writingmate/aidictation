# AIDictation v0.0.64

## Improvements
- Adds macOS 12 support for the Mac app without removing newer macOS UI behavior.
- Keeps on-device Parakeet isolated to supported macOS versions while cloud dictation remains available on older systems.
- Fixes duplicate Settings windows, restores native window controls, and normalizes Settings window layout.
- Improves cloud transcription transport selection through explicit batch/realtime/local endpoint handling.

## Fixes
- Avoids adding a random leading space before pasted transcription when text context is unknown.
- Keeps microphone, overlay, history, and onboarding UI paths compatible across supported macOS versions.

## Technical
- Adds a separate macOS 14+ Parakeet runtime framework so the main app can launch on macOS 12.
- Bumps macOS app version to 0.0.64.
