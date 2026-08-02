# Sources and claim ledger

All checks were performed on 2026-08-01. Repository paths are relative to the project root unless stated otherwise.

## Product and availability

- Product website: <https://aidictation.com>
- Open-source repository: <https://github.com/writingmate/aidictation>
- Current Android listing: <https://play.google.com/store/apps/details?id=com.aidictation.app>
- Android version `0.0.32`: `AIDictationAndroid/app/build.gradle.kts` (`versionName` and `versionCode`).
- Android 8.0 minimum: `AIDictationAndroid/app/build.gradle.kts` (`minSdk = 26`).
- Cross-platform and Android summary: `README.md`, especially the overview, feature list, platform table, offline/cloud explanation, security notes, and FAQ.

## Narration and on-screen claims

| Claim | Current implementation evidence | Wording constraint |
| --- | --- | --- |
| Keep the regular Android keyboard and add a floating mic | `AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/service/OverlayDictationAccessibilityService.kt`; `README.md` | Say “supported text fields,” never “every app.” |
| The mic appears for an active editable field | `OverlayDictationAccessibilityService.kt`, focus and eligible-node handling | App and Android restrictions can prevent insertion. |
| Tap to start, speak, tap to stop | `OverlayDictationAccessibilityService.kt`, mic click workflow; current onboarding demo in `OnboardingScreen.kt` | Do not imply background or always-on recording. |
| Finished text is inserted at the cursor | `OverlayDictationAccessibilityService.kt`, insertion and selection handling | If direct insertion fails, behavior can fall back to copy/paste. |
| Microphone and Accessibility access are used | Current Android manifest, onboarding disclosure, and service implementation | State that access is enabled with consent. |
| Secure/password fields are excluded | `OverlayDictationAccessibilityService.kt`, password-field checks; `README.md` FAQ | Do not claim support for all fields. |
| Offline recognition may require a model download | `OnboardingViewModel.kt`; `ParakeetModelAssets.kt`; `TranscriptionRepository.kt`; `README.md` | Do not say the complete workflow is always offline. |
| Cloud transcription and cleanup may process relevant audio or text remotely | `TranscriptionRepository.kt`; `README.md` offline/cloud and security sections | Keep recognition and optional cleanup distinct. |
| Personal vocabulary, writing rules, and spoken shortcuts can shape finished text | `TranscriptionRepository.kt`; current cleanup-context code; `README.md` | Present these as optional cloud features in this video. |
| AI Dictation is open source | Repository root `LICENSE` and GitHub repository | Link directly to the repository. |

## Visual provenance

The publishable composition requires these privacy-safe captures under `public/current-captures/`:

| File | Required proof | Capture rule |
| --- | --- | --- |
| `shot-accessibility-disclosure.png` | Current in-app explanation before Accessibility setup | Android 0.0.32; no account or notification content. |
| `shot-field-focused.png` | Current editable field, regular keyboard, floating mic | Use a synthetic field created for the capture. |
| `shot-result.png` | Actual dictation result inserted in that synthetic field | Record the exact spoken sample in the ledger below. |
| `shot-floating-mic.png` | Clean final view for title and thumbnail | Same current build; no personal data. |

For reproducibility, record the installed version, emulator/device model, Android version, capture time, synthetic spoken sample, and exact source path here before rendering:

- Installed app version: `0.0.32` (`1029`), package `com.aidictation.app`
- Device and Android version: Pixel emulator (`sdk_gphone64_arm64`), Android 13 / API 33
- Source revision: `e4c63d05b581992e07405bac1f0d8e51a9f12890`; Android subtree clean at capture
- Verified current capture: `shot-accessibility-disclosure.png`, 1080×2400, SHA-256 `73eedff22020969395887fcc4afb6cd21c145b2d5df9b40c6e99c5718b0c8df7`
- Capture time: 2026-08-01 current emulator session; device screenshot shows 06:59
- Spoken sample: pending; the result workflow was not captured
- Capture operator notes: The disclosure contains only generic settings text. The account identifier was scrolled out of frame before capture. The focused-field, result, and floating-mic files remain absent and must not be substituted with older assets.

## Explicit exclusions

- Do not use `AIDictationAndroid/app/src/main/play/listings/en-US/graphics/phone-screenshots/2.png`; its “99+ languages” claim is stale.
- Do not use the Play feature graphic that shows a triple-press Volume Down shortcut; that control was removed.
- Do not present Play Store composites as unmodified live product UI.
- Do not use the June 2026 onboarding captures as current 0.0.32 walkthrough footage. They are historical behavior evidence only.
- Do not use screenshots that reveal notifications, customer text, account details, secrets, or personal device content.
- Do not state current prices, “best” accuracy, speed superiority, regulatory compliance, or universal app support.
