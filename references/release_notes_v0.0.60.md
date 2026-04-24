# AIDictation v0.0.60

## Highlights
- Adds OpenAI Realtime transcription wiring through the AIDictation proxy path for faster cloud partial text.
- Defaults first-run transcription languages from enabled macOS keyboard/input-source languages.

## Fixes
- Makes Local transcription mode switch immediately while the on-device model initializes.
- Adds more spacing between overlay side buttons and the wave dots.

## Technical
- Consolidates language selection into `WhisperMateShared.LanguageManager`.
- Bumps macOS app version to 0.0.60.
