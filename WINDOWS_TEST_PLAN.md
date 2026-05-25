# Windows Release Test Plan

This plan verifies the classic Windows installer and every user-facing AIDictation Windows feature from installation through real dictation. A feature is not considered shipped unless it is tested from the installed app on Windows.

## 1. Release Gate And Environment

- Use a clean Windows 11 VM with RDP access, microphone input available, internet access, and a test AIDictation account.
- Download the `AIDictation-Windows-Installer` artifact from the latest successful Windows Build workflow.
- Verify the installer is named `AIDictation-Windows-Setup-v<version>.exe` and is larger than 10 MB.
- Verify the CI run passed build, publish, app smoke launch, installer build, installer metadata validation, and artifact upload.
- Install from the classic setup wizard using `Install for me only`.
- Confirm the install path is `%LOCALAPPDATA%\Programs\AIDictation`.
- Confirm Start search finds AIDictation after install.
- Capture screenshots for installer start, install mode, destination path, completion page, Start search result, and first app launch.

## 2. Product Mode Rules

- Windows must expose only one user-facing dictation provider. Do not ship or document a visible provider picker with Groq, custom endpoint, OpenAI, or AIDictation choices.
- Cloud dictation is the Windows provider unless a Windows offline implementation is added.
- Parakeet/offline mode is not currently present in the Windows app. Do not claim Windows Parakeet support unless Windows code adds a local runtime, model availability checks, and matching settings UI.
- Language availability is model dependent. Test language settings against the selected mode/model, not as a static universal list.
- For offline mode parity, use the macOS/Android rules as the source of truth: unsupported or low-reliability offline languages must be disabled, muted, or require a switch to cloud before selection.

## 3. First Launch And Onboarding

- Launch from the installer completion page with `Launch AIDictation` checked.
- Launch again from Start search after closing the app.
- Confirm no missing runtime prompt, crash dialog, or Defender block appears.
- With a fresh `%APPDATA%\AIDictation`, confirm onboarding opens before normal tray-only behavior.
- Complete microphone setup with a microphone connected.
- Repeat microphone setup with no microphone or microphone permission disabled, and confirm the app opens Windows microphone settings or gives a clear recovery path.
- Select languages during onboarding and verify the saved setting matches the selected language codes.
- Configure dictation and command hotkeys during onboarding.
- Complete onboarding and verify `settings.json` records onboarding completion.
- Reset app data and verify skip/back/continue paths if present.

## 4. Settings Feature Matrix

### Audio

- Open Settings from the installed app.
- Confirm the input device picker lists `Default Input Device` and available Windows capture devices.
- Select a non-default microphone, restart the app, and confirm it remains selected.
- Disconnect or disable the selected device and confirm recording falls back safely or shows a clear error.
- Select each visible language and confirm the stored language value is passed to transcription.
- In any offline/local mode implementation, verify unsupported languages are visibly unavailable or switch the app back to cloud with confirmation.

### Dictation Provider

- Confirm there is only one user-facing dictation provider path.
- Confirm hidden/internal provider branches are not exposed as product settings.
- Confirm missing cloud credentials or missing authentication shows a clear error and does not crash.
- Confirm successful cloud transcription with the release test account.

### Text Rules

- Add a dictionary entry with trigger `whisper mate` and replacement `AIDictation`; verify it persists in `dictionary.json`.
- Dictate text containing the trigger and verify the result uses the replacement.
- Disable the dictionary entry and verify the replacement no longer applies.
- Remove the dictionary entry and verify it disappears after restart.
- Add a voice shortcut with trigger `email signature` and expansion text; verify it persists in `shortcuts.json`.
- Dictate the shortcut trigger and verify expansion is applied.
- Disable and remove the shortcut, verifying behavior and persistence.
- Add a context rule with a name and instructions; verify it persists in `context_rules.json`.
- Toggle and delete the context rule. If LLM/context processing is not implemented, record that as a product gap rather than a pass.
- Try blank trigger/name fields and verify no empty rule is created.

### Hotkeys

- Set the dictation hotkey to a non-default keyboard shortcut.
- Confirm the displayed hotkey text updates immediately.
- Restart the app and confirm the hotkey remains saved.
- Use the hotkey in Notepad to start and stop recording.
- Reset the dictation hotkey and confirm it returns to the default.
- Repeat the same flow for the command hotkey.
- Try a conflicting hotkey and verify the app surfaces the conflict or rejects it.

### Overlay

- Confirm settings include Show Overlay When Idle, Overlay Position, and Overlay Color.
- Verify Overlay Color offers the macOS themes: Orange, Blue, Green, Purple, Pink, and Graphite, or record any missing theme as a failure.
- Change each overlay color and visually confirm the overlay accent updates immediately and persists after restart.
- Confirm top and bottom overlay positions work on the active display and survive restart.
- Toggle Show Overlay When Idle and confirm the idle overlay hides/shows accordingly.

## 5. macOS Bubble Parity

Use the macOS app as the visual and interaction reference. The Windows overlay must be visually compared against the macOS `RecordingOverlayView` and `OverlayWindowManager` behavior.

- Capture a macOS reference recording of the overlay in idle, hover-expanded idle, recording, recording-with-controls, processing, and collapse states.
- Capture matching Windows screenshots or video at the same scale.
- Confirm the Windows overlay is a compact capsule, not the older rectangular 280x64 panel.
- Confirm idle state matches macOS: collapsed minimal indicator, hover hit area, and themed expansion.
- Confirm live recording matches macOS: 10-dot/wave visual, smooth 0.12 second wave animation, themed background, and white waveform.
- Confirm processing matches macOS loading dots, not a spinner, unless the product intentionally changed the animation.
- Confirm morph timing matches macOS closely: 0.26 second capsule expansion, 0.14 second content fade, and 0.15 second collapse.
- Confirm click behavior:
  - Clicking the idle bubble starts recording.
  - During overlay-started recording, stop and cancel controls appear.
  - Clicking stop stops recording and enters processing.
  - Clicking cancel cancels recording and collapses without transcription.
  - Clicking the overlay does not activate or focus the main app window.
- Confirm command mode uses the command-mode visual treatment and does not conflict with dictation mode.
- Record any mismatch as a visual parity failure with side-by-side screenshots.

## 6. End-To-End Dictation

- Open Notepad.
- Start recording from the configured dictation hotkey.
- Speak: `This is a Windows dictation test.`
- Stop recording with the expected release behavior.
- Confirm the app enters recording, processing, and result states in sequence.
- Confirm transcribed text appears in the app result view.
- Confirm copy-to-clipboard works from the result view.
- Confirm text insertion or paste behavior works if the app supports auto-insertion.
- Repeat in Microsoft Edge or another editable text field.
- Repeat with punctuation: `Hello comma this is a punctuation test period`
- Repeat with a selected non-auto language supported by the current model.
- Disconnect the network during cloud dictation and confirm a clear error state.

## 7. Tray, History, And Lifecycle

- Confirm the tray icon appears after launch.
- Double-click the tray icon and verify the expected window opens.
- Open Settings from the tray. If the code path is still TODO, mark as a failure.
- Open History from the tray. If the code path is still TODO, mark as a failure.
- Quit from the tray and confirm the process exits.
- Confirm tray tooltip/icon changes during idle, recording, and processing.
- Confirm history starts with an empty state.
- Complete a successful dictation and verify a new history entry appears with timestamp, duration, and transcription preview.
- Search history by transcription text.
- Copy a history entry to the clipboard.
- Delete one entry.
- Clear all entries.
- Restart the app and confirm history persistence matches `history.json`.
- Launch a second app instance and confirm single-instance behavior prevents duplicates.
- Reboot Windows and confirm the app launches manually from Start.

## 8. Update, Uninstall, And Data

- Install the current version over a previous installed version.
- Confirm settings, text rules, history, and authentication state are preserved.
- Uninstall from Windows Apps settings.
- Confirm installed program files are removed.
- Confirm Start menu entry is removed.
- Confirm the app does not leave a running tray process.
- Confirm whether `%APPDATA%\AIDictation` is intentionally preserved or removed, and record the observed behavior.
- Reinstall after uninstall and verify first-launch behavior is correct for the retained or removed app data policy.

## 9. Release Evidence

Each release candidate must include:

- GitHub Actions run URL.
- Installer artifact name, size, and checksum.
- Windows version, VM name, and tester.
- Test account used, without recording secrets.
- Screenshots of installer, onboarding, all Settings sections, overlay colors, overlay positions, dictation result, and history.
- Side-by-side macOS and Windows overlay screenshots or video for bubble parity.
- Pass/fail table for every section in this plan.
- Explicit list of skipped tests with reasons.
- Explicit list of product gaps found during testing.
