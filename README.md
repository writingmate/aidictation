<p align="center">
  <img width="128" height="128" alt="AIDictation app icon" src="https://github.com/user-attachments/assets/e4e380ae-043f-4fe3-9968-56a03851e1c2" />
</p>

<h1 align="center">AIDictation</h1>

<p align="center">
  Fast, native voice-to-text for macOS, Windows, and Android.
</p>

<p align="center">
  <a href="https://aidictation.com">Website</a>
  ·
  <a href="https://www.youtube.com/watch?v=FQkePjWlDqY">Video overview</a>
  ·
  <a href="https://github.com/writingmate/aidictation/releases">All releases</a>
</p>

<p align="center">
  <img width="812" height="612" alt="AIDictation screenshot" src="https://github.com/user-attachments/assets/334c3d93-d1e5-4bba-9402-d451f917457a" />
</p>

## Download

| App | Latest | Download |
| --- | --- | --- |
| macOS | v0.0.92 | [Download DMG](https://github.com/writingmate/aidictation/releases/download/v0.0.92/AIDictation-v0.0.92.dmg) |
| Windows | v0.0.4 | [Download installer](https://github.com/writingmate/aidictation/releases/download/windows-v0.0.4/AIDictation-Windows-Setup-v0.0.4.exe) · [Portable ZIP](https://github.com/writingmate/aidictation/releases/download/windows-v0.0.4/AIDictation-Windows-v0.0.4.zip) |
| Android | v0.0.29 | [Download APK](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/AIDictation-Android-0.0.29.apk) · [Play upload AAB](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/AIDictation-Android-0.0.29.aab) · [Checksums](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/SHA256SUMS.txt) |

## What It Does

AIDictation turns your voice into text and inserts it into the app you are already using. It supports quick hold-to-dictate recording, continuous dictation, custom writing rules, glossary terms, shortcuts, and optional cleanup after transcription.

## Highlights

- Native apps for macOS, Windows, and Android
- Fast voice-to-text with cloud mode
- Offline mode on Android with downloadable on-device speech recognition
- Privacy-focused local handling of recordings and settings
- Secure storage for local app credentials
- Custom dictionary, writing style, and shortcut support
- Floating controls designed for writing in any app

## Install

### macOS

1. Download the [latest DMG](https://github.com/writingmate/aidictation/releases/download/v0.0.92/AIDictation-v0.0.92.dmg).
2. Open the DMG.
3. Drag AIDictation to Applications.
4. Launch AIDictation and follow setup.
5. Enable microphone and accessibility access when prompted.

### Windows

1. Download the [latest installer](https://github.com/writingmate/aidictation/releases/download/windows-v0.0.4/AIDictation-Windows-Setup-v0.0.4.exe).
2. Run the installer.
3. Launch AIDictation from the Start menu.
4. Follow setup and allow microphone access.

For a no-install option, download the [portable ZIP](https://github.com/writingmate/aidictation/releases/download/windows-v0.0.4/AIDictation-Windows-v0.0.4.zip), extract it, and run the app from the extracted folder.

### Android

1. Download the [latest APK](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/AIDictation-Android-0.0.29.apk).
2. Open the APK on your Android device.
3. Allow installation from your browser or file manager if Android asks.
4. Launch AIDictation and follow setup.
5. Enable microphone and accessibility access when prompted.

The Android release also includes an [AAB](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/AIDictation-Android-0.0.29.aab) for Play Console uploads and [SHA-256 checksums](https://github.com/writingmate/aidictation/releases/download/android-v0.0.29/SHA256SUMS.txt) for verifying downloads.

## Build From Source

### macOS and iOS

Requirements:

- macOS 13 or later
- Xcode 15 or later

```bash
git clone https://github.com/writingmate/aidictation.git
cd aidictation/Whishpermate
open Whispermate.xcodeproj
```

Build and run from Xcode.

### Windows

Requirements:

- Windows 10 or later
- Visual Studio 2022 with .NET desktop development tools

```powershell
git clone https://github.com/writingmate/aidictation.git
cd aidictation\AIDictation.Windows
dotnet build AIDictation.sln
```

### Android

Requirements:

- Android Studio or Android SDK command-line tools
- JDK 17

```bash
git clone https://github.com/writingmate/aidictation.git
cd aidictation/AIDictationAndroid
./gradlew assembleDebug
```

Copy `AIDictationAndroid/local.properties.template` to `local.properties` when you need local cloud-mode configuration.

## Privacy

- Recordings are temporary and are not kept as app data after transcription.
- Cloud mode sends audio to the configured transcription service.
- Offline mode processes speech on the device where supported.
- App credentials are stored in the operating system's secure storage.

## Repository Layout

```text
AIDictationAndroid/      Android app
AIDictation.Windows/    Windows app
Whishpermate/           macOS and iOS apps
ci_scripts/             Shared release and signing helpers
scripts/                Release validation tools
references/             Release notes and supporting docs
```

## License

MIT
