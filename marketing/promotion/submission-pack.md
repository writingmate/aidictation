# AI Dictation submission pack

Last verified: 2026-08-02

This is the canonical copy bank for directory, marketplace, app-catalog, and launch submissions. Recheck any field that can change (pricing, usage limits, supported languages, release versions, and store requirements) on the day of submission.

## License verification

The canonical repository's default branch contains the root MIT `LICENSE` and `THIRD_PARTY_NOTICES.md`, and GitHub detects the repository license as MIT. The native Apple, Windows, and Android client source is available under MIT; bundled third-party components retain their own licenses. Do not describe private hosted services or the website implementation as MIT-licensed unless their licensing is separately verified.

## Canonical identity and URLs

| Field | Canonical value |
| --- | --- |
| Product name | AI Dictation |
| Compact name where spaces are disallowed | AIDictation |
| Website | https://aidictation.com |
| Download page | https://aidictation.com/download |
| Source repository | https://github.com/writingmate/aidictation |
| Releases | https://github.com/writingmate/aidictation/releases |
| Issue tracker | https://github.com/writingmate/aidictation/issues |
| Privacy policy | https://aidictation.com/privacy |
| FAQ | https://aidictation.com/faq |
| App Store | https://apps.apple.com/app/id6754910103 |
| Google Play | https://play.google.com/store/apps/details?id=com.aidictation.app |
| YouTube channel | https://www.youtube.com/@ArtemVysotsky |
| Existing demo | https://www.youtube.com/watch?v=FQkePjWlDqY |
| Support | support@aidictation.com |

Use clean canonical URLs without UTM parameters in permanent directory listings unless a directory requires a campaign URL. Never use an APK mirror as the official Android URL.

## Names, headline, and tagline

- Product: `AI Dictation`
- Descriptive headline: `Open-source voice-to-text for desktop and mobile`
- Short tagline: `Speak naturally. Get usable text where you write.`
- Repository title: `AI Dictation — Open-Source Voice-to-Text App`
- One-sentence positioning: `AI Dictation is a cross-platform voice-to-text app with MIT-licensed native client source, offline recognition on supported devices, and optional cloud transcription and cleanup.`

## Length-controlled descriptions

Counts include spaces and punctuation. Each value is one line; do not copy the surrounding code fence. Recount after any edit.

### Up to 60 characters

```text
Cross-platform dictation with MIT-licensed client source.
```

Count: **57**

### Up to 160 characters

```text
AI Dictation is a cross-platform voice-to-text app with MIT-licensed native client source, offline recognition on supported devices, and optional cloud cleanup.
```

Count: **160**

### Up to 500 characters

```text
AI Dictation is a cross-platform voice-to-text app for macOS, Windows, iPhone, iPad, and Android. Start dictation with a desktop shortcut, the iOS voice keyboard, or Android’s floating microphone. Choose offline recognition on supported devices or optional cloud transcription and cleanup. Personal-vocabulary and writing controls vary by platform. Native Apple, Windows, and Android client source is available under the MIT License; third-party components keep their own licenses.
```

Count: **481**

### Up to 1,500 characters

```text
AI Dictation is a cross-platform voice-to-text app for macOS, Windows, iPhone, iPad, and Android. Dictate in supported text fields with a desktop shortcut, the AI Dictation iOS keyboard, or Android’s floating microphone. Platform behavior varies because each operating system handles audio capture and text insertion differently. Choose offline speech recognition on supported devices or optional cloud transcription and cleanup. A local model may require a one-time download. Depending on the platform, personal vocabulary, replacements, spoken shortcuts, and writing rules provide more control over the result. AI Dictation instructs cleanup to use reference terms only when the recorded speech supports them. Offline recognition and a fully offline workflow are not the same: cloud transcription sends audio for processing, and optional cloud cleanup may send transcript text even after local recognition. Some workflows retain recordings locally for history, replay, recovery, or retry; temporary recordings may be removed after successful processing. Native Apple, Windows, and Android client source is available under the MIT License; bundled third-party components keep their own licenses. Download at https://aidictation.com/download, review the source at https://github.com/writingmate/aidictation, and read the privacy policy at https://aidictation.com/privacy.
```

Count: **1,371**

## Categories and tags

Use only the categories a destination actually offers.

- Primary category: `Productivity`
- Secondary categories: `Voice to text`, `Speech recognition`, `Dictation`, `Writing tools`
- Optional category when the directory's definition fits: `Accessibility`
- Source-code category: `Open source`

Recommended tags, in priority order:

1. `ai-dictation`
2. `voice-to-text`
3. `speech-to-text`
4. `dictation`
5. `voice-typing`
6. `speech-recognition`
7. `offline-speech-recognition`
8. `transcription`
9. `writing-assistant`
10. `personal-vocabulary`
11. `macos`
12. `windows`
13. `ios`
14. `android`
15. `open-source`

Do not tag the app `self-hosted`: the repository contains native applications, not a documented self-hosted cloud service.

## Platform wording

Preferred broad wording:

> Available for macOS 13+, 64-bit Windows 10+, iPhone and iPad on iOS 15+, and Android 8+; dictation starts from configurable desktop shortcuts, the AI Dictation iOS keyboard, or Android’s floating microphone in supported editable fields.

Requirements currently documented in the repository:

| Platform | Minimum documented requirement | Input method |
| --- | --- | --- |
| macOS | macOS 13 or later | Configurable global shortcut |
| Windows | 64-bit Windows 10 or later | Configurable global shortcut |
| iPhone and iPad | iOS 15 or later | AI Dictation keyboard |
| Android | Android 8.0 or later | Floating microphone |

Offline recognition on Apple platforms requires macOS 14+ or iOS 17+; feature and history behavior varies by platform and workflow. Do not say the app works in *every* app: secure fields, password fields, and applications that restrict accessibility or third-party keyboard input may not accept dictation.

## License and commercial-model wording

> The macOS, iOS, Windows, and Android application source is available under the MIT License. Bundled third-party components remain under their respective licenses; see `THIRD_PARTY_NOTICES.md`.

If a directory has separate license and pricing fields:

- Source-code license: `MIT`
- License class: `Open Source`
- Product-access model: recheck the official website on the submission date; it currently presents both free and paid access.
- When forced to select one commercial label, `Freemium` is the least misleading current choice, but it is not a substitute for the MIT source-code license.

Never copy a price, discount, word allowance, refund period, or AppSumo package into a durable directory description. Those values change independently of the source-code license.

## Privacy wording

Short:

> Offline speech recognition runs on the device where supported. Cloud transcription sends audio for processing, and optional cloud cleanup may send transcript text even after offline recognition.

Full:

> Offline speech recognition runs on the device where supported. Cloud transcription sends audio to service providers so the requested feature can run, and optional cloud cleanup may send transcript text even after offline recognition. Some workflows retain recordings locally for history, replay, recovery, or retry; other temporary recordings are removed after successful processing. The privacy policy states that AI Dictation does not sell recordings, transcripts, or personal information. Read the current policy at https://aidictation.com/privacy.

Do not use `fully private`, `100% private`, `nothing leaves the device`, `HIPAA compliant`, `SOC 2 compliant`, or similar blanket wording. A fully offline result requires the user to select supported local recognition and disable cloud cleanup and other cloud writing features.

## Reusable feature bullets

Use only the bullets supported by the target platform or workflow; feature and history behavior varies.

- Voice typing in supported text fields across macOS, Windows, iPhone, iPad, and Android.
- Offline speech recognition on supported devices, with cloud transcription available as another mode.
- Optional cleanup and formatting after recognition.
- Personal vocabulary for intended spellings of names, products, acronyms, and specialist terms.
- Explicit replacements, spoken shortcuts, and writing rules where those controls are available.
- Local history for review, replay, or recovery where the platform supports it.
- MIT-licensed native client source for the Apple, Windows, and Android apps.

Do not claim a benchmarked accuracy, speed multiplier, language count, install count, user count, or “best” ranking without dated primary evidence.

## Asset paths

All paths are relative to the repository root.

| Use | Path | Dimensions | Notes |
| --- | --- | ---: | --- |
| General/macOS icon | `Whishpermate/Whispermate/Assets.xcassets/AppIcon.appiconset/1024-mac.png` | 1024×1024 | Transparent PNG; preferred general directory icon after a visual brand check |
| iOS icon | `Whishpermate/WhisperMateIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | 1024×1024 | Opaque square App Store icon |
| Windows icon | `AIDictation.Windows/Assets/app.png` | 1024×1024 | Opaque square Windows asset |
| Android icon | `AIDictationAndroid/app/src/main/play/listings/en-US/graphics/icon/1.png` | 512×512 | Production Google Play icon |
| Android feature graphic | `AIDictationAndroid/app/src/main/play/listings/en-US/graphics/feature-graphic/1.png` | 1024×500 | Android-specific; do not present as a cross-platform hero |
| Android screenshots | `AIDictationAndroid/app/src/main/play/listings/en-US/graphics/phone-screenshots/1.png` through `5.png` | 2160×3840 | Production store screenshots |
| iOS screenshots | `Whishpermate/Screenshots/iOS/01-onboarding.png`, `02-microphone-permission.png`, `03-keyboard-setup.png`, and `04-main-ready.png` | 1320×2868 | Stale WhisperMate branding; do not upload |
| macOS screenshot | `screenshot.png` | 892×732 | Too small for destinations requiring at least 1280×800 |

Publicly hosted assets already used by the repository documentation:

- Icon: `https://github.com/user-attachments/assets/e4e380ae-043f-4fe3-9968-56a03851e1c2`
- macOS screenshot: `https://github.com/user-attachments/assets/334c3d93-d1e5-4bba-9402-d451f917457a`
- Current App Store screenshot showing context controls: `https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/72/9a/31/729a31f0-ad06-f50a-438a-0219998c38ad/4__U00283_U0029.png/600x1300bb-60.jpg`

Asset gaps to fix before broad distribution:

- A current cross-platform 1200×630 or 1600×900 landscape hero.
- A current macOS screenshot at 1280×800 or larger for Setapp and editorial catalogs.
- Current Windows screenshots suitable for the Microsoft Store and download catalogs.
- A public brand-kit folder or release attachment with stable URLs.

Do not upload development screenshots from `AIDictationAndroid/device-shots/` as marketing assets.

## Truthful FAQ answers

### What is AI Dictation?

AI Dictation is a cross-platform voice-to-text app. It lets people dictate in supported text fields and, depending on the platform and workflow, can apply optional cleanup, personal vocabulary, replacements, writing rules, and spoken shortcuts.

### Is AI Dictation open source?

Yes. The native macOS, iOS, Windows, and Android client source is available under the MIT License. Bundled third-party components retain their own licenses.

### Which platforms are supported?

The repository and download page provide apps for macOS, Windows, iPhone, iPad, and Android. The interaction differs by platform: desktop shortcut, iOS keyboard, or Android floating microphone.

### Does it work offline?

Offline speech recognition is available on supported devices and may require a model download. Optional cloud cleanup can still send transcript text after local recognition, so offline recognition alone does not guarantee a fully offline workflow.

### Does it work in every app?

It works in supported standard text fields. Password fields, secure fields, and applications that block accessibility or third-party keyboard input may not accept dictation.

### What happens to audio and transcript data?

Local recognition processes supported transcription on the device. Cloud transcription sends audio for processing, and cloud cleanup may send transcript text. Some workflows keep recordings locally for history, replay, recovery, or retry. The complete current terms are at https://aidictation.com/privacy.

### Does personal vocabulary force words into a transcript?

Personal vocabulary supplies reference spellings. AI Dictation instructs cleanup to use reference terms only when supported by the recorded speech, so adding a term is not intended to insert it into unrelated transcripts.

### Is there a free version?

The official website currently presents free access as well as paid access. Because limits and prices can change, link to https://aidictation.com instead of copying numeric pricing into a durable listing.

### Can I use the source commercially?

The repository's own code can be used under the MIT License. Any bundled third-party component remains subject to its own license, so review `THIRD_PARTY_NOTICES.md` before redistribution.

### Where should people report bugs or security issues?

Use https://github.com/writingmate/aidictation/issues for ordinary reproducible bugs. Send security reports privately to support@aidictation.com and do not attach real recordings, transcripts, credentials, or other sensitive data to a public issue.

## Final pre-submission checklist

- Confirm the root MIT `LICENSE` and `THIRD_PARTY_NOTICES.md` are still present on the default branch.
- Search the destination for an existing listing before creating a duplicate.
- Use `https://aidictation.com` as the official website.
- Use the relevant first-party store URL for mobile downloads.
- Recheck platform requirements and current release links.
- Recheck all screenshots against the current user interface.
- Remove numeric pricing, limits, metrics, rankings, and unsupported compliance claims.
- Keep privacy wording conditional on offline/cloud mode.
- Record the submitted copy, date, account, and result in `directory-tracker.md`.
- Inspect the published page separately for indexability and link attributes; never infer `dofollow` from approval alone.
