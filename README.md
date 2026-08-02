<p align="center">
  <img
    width="128"
    height="128"
    alt="AI Dictation app icon"
    src="https://github.com/user-attachments/assets/e4e380ae-043f-4fe3-9968-56a03851e1c2"
  />
</p>

<h1 align="center">AI Dictation — Open-Source Voice-to-Text App</h1>

<p align="center">
  Native voice typing and speech-to-text for macOS, Windows, iPhone, iPad, and Android.
</p>

<p align="center">
  <a href="https://aidictation.com/download"><img alt="Download AI Dictation" src="https://img.shields.io/badge/Download-AI_Dictation-ff7a1a"></a>
  <a href="https://github.com/writingmate/aidictation/releases"><img alt="Latest GitHub release" src="https://img.shields.io/github/v/release/writingmate/aidictation?filter=v%2A&sort=semver"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-2ea44f"></a>
</p>

AI Dictation is an [MIT-licensed](LICENSE), open-source speech-to-text app for macOS, Windows, iPhone, iPad, and Android. It provides voice typing in supported apps with offline recognition, optional cloud transcription and cleanup, personal vocabulary, writing rules, and spoken shortcuts. Feature availability varies by platform and workflow.

<p align="center">
  <a href="https://aidictation.com/download">Download for Mac or Windows</a>
  ·
  <a href="https://apps.apple.com/app/id6754910103">Install on iPhone or iPad</a>
  ·
  <a href="https://play.google.com/store/apps/details?id=com.aidictation.app">Install on Android</a>
  ·
  <a href="https://www.youtube.com/watch?v=FQkePjWlDqY">Watch the demo</a>
  ·
  <a href="https://github.com/writingmate/aidictation/releases">Browse releases</a>
</p>

<p align="center">
  <img
    width="812"
    height="612"
    alt="AI Dictation for macOS ready to start voice typing with a keyboard shortcut"
    src="https://github.com/user-attachments/assets/334c3d93-d1e5-4bba-9402-d451f917457a"
  />
</p>

## Voice typing where you already work

AI Dictation provides native voice input controls for each platform:

- Use a configurable shortcut on macOS and Windows.
- Use the AI Dictation voice keyboard on iPhone and iPad.
- Keep your regular Android keyboard and add a floating microphone beside editable text fields.
- Dictate in supported messages, email, notes, documents, browsers, and other standard text fields.
- Choose offline recognition when supported or cloud transcription when you want it.
- Use the personal-vocabulary, replacement, writing-rule, and spoken-shortcut controls available on your platform.
- Apply optional cleanup and formatting after transcription.
- Keep local history for review, replay, and recovery where the platform supports it.

Platform behavior differs because macOS, Windows, iOS, and Android provide different ways to capture and insert text.

## Download AI Dictation

| Platform | Install | Requirements | Voice input |
| --- | --- | --- | --- |
| macOS | [Download for Mac](https://aidictation.com/download) | macOS 13 or later | Configurable global shortcut |
| Windows | [Download for Windows](https://aidictation.com/download) | 64-bit Windows 10 or later | Configurable global shortcut |
| iPhone and iPad | [Download on the App Store](https://apps.apple.com/app/id6754910103) | iOS 15 or later | AI Dictation keyboard |
| Android | [Get it on Google Play](https://play.google.com/store/apps/details?id=com.aidictation.app) | Android 8.0 or later | Floating microphone |

The macOS app installs on macOS 13 or later, while offline recognition requires macOS 14 or later. The iOS offline model and Live Activity require iOS 17 or later. Android APKs, Windows portable builds, checksums, and other release assets are available from [GitHub Releases](https://github.com/writingmate/aidictation/releases).

## How AI Dictation works

1. Install the app and grant the permissions required by your platform.
2. Place the cursor in a supported text field.
3. Start recording with the desktop shortcut, iOS keyboard, or Android floating microphone.
4. Speak naturally and stop when you are finished.
5. AI Dictation transcribes the recording, applies any enabled cleanup and personal rules, and returns the finished text.

## Offline speech recognition or cloud transcription

AI Dictation lets you choose how speech recognition runs on supported devices.

| | Offline mode | Cloud mode |
| --- | --- | --- |
| Speech recognition | Runs on the device | Sends the recording to the transcription service |
| Internet connection | Not required after the local model is ready | Required |
| Model setup | May require a one-time model download | No local speech model required |
| Optional cleanup | Cloud cleanup may still send the transcript when enabled | Cleanup may send the transcript for processing |
| Useful when | You need local recognition or have no connection | You choose cloud recognition and cleanup |

Some platforms also provide Automatic mode, which chooses between available offline and cloud recognition.

Offline speech recognition and a fully offline workflow are not necessarily the same thing. If nothing should leave the device, confirm that cloud cleanup and other cloud writing features are disabled.

## Personal vocabulary, replacements, and voice shortcuts

AI Dictation can use your reference context to improve the final transcript:

- **Personal vocabulary** supplies the intended spelling of names, products, acronyms, and specialist terms.
- **Replacements** map a spoken form to the text you want returned.
- **Voice shortcuts** expand a spoken trigger into a phrase you use frequently.
- **Writing rules** control formatting, tone, or structure for a particular context.

AI Dictation instructs cleanup to use reference terms only when the recorded speech supports them; adding a term is not intended to insert it into unrelated transcripts.

## How AI Dictation differs from basic dictation software

Built-in dictation and browser speech recognition are useful for quick voice typing. AI Dictation is designed for people who want more control over where recognition runs and how the final text is shaped.

| Need | AI Dictation approach |
| --- | --- |
| Dictate where you write | Platform-specific desktop, keyboard, and floating-microphone controls |
| Keep speech recognition local | Offline mode on supported devices |
| Clean up rough speech | Optional cleanup and formatting |
| Handle names and jargon | Personal vocabulary and explicit replacements |
| Reuse common phrases | Spoken shortcuts |
| Adapt output to context | Writing and app-context rules |
| Inspect or extend the implementation | MIT-licensed native client source for Apple, Windows, and Android |

This comparison describes AI Dictation's implementation without making unsupported accuracy, speed, or “best app” claims.

## Build from source

Clone the repository once:

```bash
git clone https://github.com/writingmate/aidictation.git
cd aidictation
```

### Build for macOS or iOS

Requirements:

- Xcode 26 or the current Xcode version used by the Apple CI workflow
- A macOS version supported by that Xcode release

```bash
cd Whishpermate
open Whispermate.xcodeproj
```

Select the macOS or iOS scheme in Xcode and run it.

### Build for Windows

Requirements:

- Windows 10 or later
- Visual Studio 2022 with .NET desktop development tools, or the .NET 8 SDK

```powershell
cd AIDictation.Windows
dotnet build AIDictation.sln
```

### Build for Android

Requirements:

- Android Studio or Android SDK command-line tools
- JDK 17

```bash
cd AIDictationAndroid
./gradlew assembleDebug
```

Copy `local.properties.template` to `local.properties` only when a local build needs cloud-mode configuration. Do not commit API credentials.

## Privacy and data processing

- Offline speech recognition processes audio on the device.
- Cloud transcription sends the recording to the transcription service.
- Optional cloud cleanup can send a transcript even when speech recognition ran offline.
- Some workflows keep recordings locally for history, replay, recovery, or retry; other temporary recordings are removed after successful processing.
- Account session tokens and user-entered API keys are stored using platform secure storage where applicable.

Read the [AI Dictation privacy policy](https://aidictation.com/privacy) for the complete and current terms.

## Frequently asked questions

### What is AI Dictation?

AI Dictation is a cross-platform voice-to-text app that lets you dictate into supported apps on macOS, Windows, iPhone, iPad, and Android. Depending on the platform and workflow, it combines offline or cloud speech recognition with optional cleanup, personal vocabulary, writing rules, and voice shortcuts.

### Is AI Dictation open source?

Yes. AI Dictation's native client source is available under the [MIT License](LICENSE): [macOS and iOS](Whishpermate/), [Windows](AIDictation.Windows/), and [Android](AIDictationAndroid/). Bundled third-party components remain under their own licenses; see [Third-Party Notices](THIRD_PARTY_NOTICES.md).

### Does AI Dictation work offline?

Offline speech recognition is available on supported devices and languages. A model download may be required first. Cloud cleanup can still send transcript text when enabled, so disable cloud features when the complete workflow must remain on-device.

### Does AI Dictation work in every app?

It works in standard supported text fields, but operating-system and application restrictions apply. Password fields, secure fields, and apps that block accessibility or third-party keyboard input may not accept dictation.

### Is AI Dictation a voice keyboard?

On iPhone and iPad, AI Dictation includes a voice-to-text keyboard. On Android, it adds a floating microphone while allowing you to keep your existing keyboard. The desktop apps use configurable shortcuts.

### How is AI Dictation different from built-in speech recognition software?

Depending on the platform and workflow, AI Dictation can add selectable offline or cloud processing, optional cleanup, personal vocabulary, replacements, spoken shortcuts, context rules, and local history. No accuracy comparison is implied without a reproducible benchmark.

### Is a free version available?

A free tier is available. Check [aidictation.com](https://aidictation.com) for current usage limits and paid-plan details instead of relying on versioned pricing in this README.

### Where can I report a problem?

Use [GitHub Issues](https://github.com/writingmate/aidictation/issues) for reproducible bugs and feature requests. Do not include recordings, transcripts, credentials, or other sensitive data in a public issue.

## Repository layout

```text
AIDictationAndroid/      Android app
AIDictation.Windows/    Windows app
Whishpermate/            macOS and iOS apps
ci_scripts/              Shared release and signing helpers
docs/                    Architecture and reliability contracts
scripts/                 Build, release, and validation tools
references/              Release notes and supporting material
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and use [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## Project links

- [AI Dictation website](https://aidictation.com)
- [Download AI Dictation](https://aidictation.com/download)
- [AI Dictation FAQ](https://aidictation.com/faq)
- [Privacy policy](https://aidictation.com/privacy)
- [Release history](https://github.com/writingmate/aidictation/releases)
- [Issue tracker](https://github.com/writingmate/aidictation/issues)
- [YouTube channel](https://www.youtube.com/@ArtemVysotsky)

## License

AI Dictation's native client source is available under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components distributed under other licenses.
