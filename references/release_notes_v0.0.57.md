# AIDictation v0.0.57

## Highlights
- Refined the bottom recording overlay with distinct idle, hover/Fn, recording, and processing states.
- Added status-bar microphone selection with automatic input selection.
- Added configurable overlay colors.

## Fixes
- Persist auth sessions in Keychain while migrating legacy UserDefaults sessions.
- Keep Settings and status-bar transcription mode selection on the same runtime manager.
- Apply the same local-model readiness policy from Settings and the status-bar menu.
- Persist selected microphone state only after Core Audio accepts the device.

## Technical
- Preserved the original idle pill and dot sizing while scaling expanded overlay states.
- Removed the overlay context-role detection/display path for now.
- Added shared transcription-mode request handling.
- Added audio-device refresh and automatic-selection plumbing.
