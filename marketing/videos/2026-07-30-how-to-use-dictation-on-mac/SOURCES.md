# Sources and claims

Checked 2026-07-30. This file separates product evidence, Apple documentation, conceptual visuals, and user-provided keyword research.

## Apple built-in Dictation

- Apple Support, “Dictate messages and documents on Mac”: https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac
  - Supports the path `System Settings → Keyboard → Dictation`.
  - Supports choosing Dictation languages, microphone source, and keyboard shortcut.
  - Supports starting from the Microphone key, a configured shortcut, or `Edit → Start Dictation`.
  - Supports stopping with Escape, the Microphone key, or the configured shortcut.
- No Apple or competitor result is shown or simulated. The built-in section uses instructional motion graphics, not a fabricated System Settings screenshot.

## AI Dictation product behavior

- Repository README (`README.md`):
  - macOS uses a configurable global shortcut.
  - Local recognition is available on supported Macs and languages; cloud transcription and cleanup are optional.
  - Personal vocabulary, replacements, writing rules, and spoken shortcuts can shape the final transcript.
  - AI Dictation is open source under the MIT license.
- macOS onboarding (`Whishpermate/Whispermate/Services/OnboardingManager.swift` and `Whishpermate/Whispermate/Views/OnboardingView.swift`):
  - Users choose a hotkey; onboarding proposes Fn but users can choose another.
  - Press and hold records; double-tap starts or stops a longer recording.
  - Accessibility permission is used to paste transcriptions into apps.
- macOS hotkey implementation (`Whishpermate/Whispermate/Services/HotkeyManager.swift`):
  - Push-to-talk defaults on.
  - Double-tap detection is implemented for the Dictation hotkey.
- macOS insertion implementation (`Whishpermate/Whispermate/Services/ClipboardManager.swift` and `Whishpermate/Whispermate/Services/AppState.swift`):
  - Completed text is inserted into the target/active app via the guarded cross-app insertion path.

## Visual assets

- `public/aidictation-icon.png` is copied unchanged from the current macOS AppIcon asset catalog.
- `public/aidictation-dictation.png` is copied unchanged from the current macOS onboarding asset catalog. It is used as branded onboarding art, not described as a live screenshot.
- The repository’s older `screenshot.png` was audited and intentionally excluded from the video because it no longer represents the current Mac interface.
- The document-style panel in the result scene is labeled “Conceptual text field” in-frame. It illustrates the insertion flow and is not presented as an app or competitor screenshot.
- No current real Mac product screenshot was available in the repository at
  production time. Add and document a current, privacy-safe capture before
  rendering a publishable launch-video cut.

## Claims intentionally not made

- No claim that AI Dictation is more accurate, faster, more private, or “best.”
- No benchmark or competitor output.
- No claim that local recognition means the complete workflow is offline when cloud cleanup is enabled.
- No claim that every app, language, or device supports every option.
- No promotion of the currently unshipped command mode.

## Important qualifiers

- Say “supported” or “standard” text fields, not every app.
- Local recognition requires a supported Mac, language, and model setup. Cloud cleanup can still send transcript text when enabled.
- Writing/context rules that depend on cleanup require cloud processing.

## Keyword brief

- Target: `How to Use Dictation on Mac (Built-In + AI)`.
- Semrush US volume `2,400` and keyword difficulty `37` were supplied in the task brief and were not independently re-queried for this pilot.
