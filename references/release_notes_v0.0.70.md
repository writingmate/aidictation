Stabilizes dictation insertion across real macOS text fields.

- Uses a guarded pasteboard paste path for normal insertion, then restores the prior clipboard contents when untouched.
- Sends the trailing insertion space as a real key event so fields like the Chrome address bar keep it.
- Avoids Accessibility value rewrites that can damage rich editor formatting.
- Treats AIDictation cloud transcription as app-authenticated, without asking users for their own API key.
- Adds a menu bar icon visibility toggle and pads macOS app icon assets to avoid clipped system-list rendering.
