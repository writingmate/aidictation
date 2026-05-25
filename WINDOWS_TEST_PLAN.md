# Windows Release Test Plan

This plan verifies the classic Windows installer and the installed AIDictation app from installation through onboarding and core dictation behavior.

## 1. Installer Gate

- Download the `AIDictation-Windows-Installer` artifact from the latest successful Windows Build workflow.
- Verify the installer is named `AIDictation-Windows-Setup-v<version>.exe`.
- Verify the installer is signed when code signing is enabled for release builds.
- Launch the installer on a clean Windows 11 VM.
- Confirm the classic setup wizard opens with AIDictation branding and version.
- Choose `Install for me only`.
- Confirm the default destination is under `%LOCALAPPDATA%\Programs\AIDictation`.
- Complete setup with `Launch AIDictation` enabled.
- Confirm AIDictation appears in Windows Start search after installation.
- Confirm uninstall entry exists from the Start menu or Apps settings.

## 2. First Launch And Onboarding

- Launch AIDictation from the installer finish screen.
- Launch AIDictation again from Windows Start search.
- Confirm the app starts without a crash dialog or missing runtime prompt.
- Confirm the tray/taskbar behavior matches the product expectation.
- Complete every onboarding prompt with a first-time user account.
- Confirm the app explains microphone access in user-facing language.
- Deny microphone access once and confirm the recovery path is clear.
- Grant microphone access and confirm the app proceeds.
- Confirm cloud/offline mode labels use product terms, not provider or implementation names.

## 3. Account And Settings

- Sign in with a test account.
- Sign out and sign back in.
- Confirm settings persist after app restart.
- Toggle offline mode and cloud mode.
- Confirm any unavailable mode shows a clear user-facing message.
- Confirm app restart preserves the selected mode.

## 4. Voice Dictation

- Open Notepad.
- Start dictation from the expected hotkey or app control.
- Dictate a short sentence: `This is a Windows dictation test.`
- Confirm text appears in Notepad accurately enough for release criteria.
- Pause dictation and confirm no new text is inserted.
- Resume dictation and confirm insertion continues.
- Stop dictation and confirm microphone capture stops.
- Repeat with a second app, such as Microsoft Edge address bar or a web text field.
- Verify punctuation and capitalization handling.
- Verify behavior when the network is disconnected if offline mode is supported.

## 5. Runtime Reliability

- Restart the app five times.
- Reboot Windows and launch AIDictation from Start.
- Confirm no duplicate tray icons are left behind.
- Confirm CPU and memory remain stable while idle for 10 minutes.
- Confirm no Windows Defender SmartScreen or runtime dependency prompt blocks launch.
- Confirm logs do not contain unhandled exceptions.

## 6. Update And Uninstall

- Install the current release over the previous release.
- Confirm settings and account state are preserved.
- Uninstall AIDictation from Windows Apps settings.
- Confirm app files are removed from the install directory.
- Confirm user data handling matches the product policy.
- Reinstall after uninstall and confirm onboarding behavior is correct.

## 7. Release Evidence

Each release candidate should attach:

- GitHub Actions run URL with successful build, publish, app smoke launch, installer build, and installer metadata checks.
- Installer artifact name and size.
- Screenshot of the installer install-mode page.
- Screenshot of the destination page.
- Screenshot of the completion page with launch enabled.
- Screenshot of AIDictation found in Windows Start search after install.
- Manual dictation result screenshot or recording.
- Notes for any skipped checks and the reason they were skipped.
