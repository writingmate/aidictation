# AIDictation v0.0.66

## Fixes
- Fixed login deeplinks opening duplicate Settings windows.
- Tightened Settings window reuse so auth, onboarding, Dock, and menu paths share one window.
- Restored the correct Settings window size for new windows.

## Technical
- URL callbacks are now handled by the app delegate only.
- Release target verified as `Whispermate` / `AIDictation.app` with macOS 12.0 deployment target.
