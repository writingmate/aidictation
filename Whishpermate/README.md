# AI Dictation for Apple Platforms

This directory contains the native macOS, iPhone, and iPad apps for [AI Dictation](https://aidictation.com). Start with the [repository README](../README.md) for product downloads, supported platforms, privacy information, and the complete build overview.

## Requirements

- macOS 13 or later to run the Mac app
- iOS 15 or later to run the iPhone or iPad app
- Xcode 15 or later

Some features use newer operating-system APIs. Offline speech recognition and Live Activity support on iOS require iOS 17 or later.

## Open the project

```bash
open Whispermate.xcodeproj
```

Use the `Whispermate` scheme for macOS or the `WhisperMateIOS` scheme for iOS.

## Build from the command line

Build the macOS app:

```bash
xcodebuild \
  -project Whispermate.xcodeproj \
  -scheme Whispermate \
  -configuration Debug \
  build
```

List available iOS destinations before choosing a simulator:

```bash
xcodebuild \
  -project Whispermate.xcodeproj \
  -scheme WhisperMateIOS \
  -showdestinations
```

## Directory guide

```text
Whispermate/             macOS app
WhisperMateIOS/          iPhone and iPad app
WhisperMateKeyboard/     iOS keyboard extension
WhisperMateShared/       Shared Apple-platform code
Whispermate.xcodeproj/   Xcode project and shared schemes
fastlane/                Store metadata and release automation
```

## Before contributing

- Read the root [contribution guide](../CONTRIBUTING.md).
- Follow the shared [audio-processing failure contract](../docs/audio-processing-failure-contract.md).
- Never commit signing credentials, API keys, recordings, or transcripts.
- Verify changes on every Apple target they affect.

## License

AI Dictation is available under the repository's [MIT License](../LICENSE). Bundled third-party components remain under their respective licenses; see [third-party notices](../THIRD_PARTY_NOTICES.md).
