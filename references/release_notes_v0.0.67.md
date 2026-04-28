# AIDictation v0.0.67

## Fixes
- Fixed dictation paste sometimes inserting the previous clipboard value instead of the spoken text.
- Kept the v0.0.66 Settings/deeplink fixes: one Settings window, correct window sizing, and macOS 12.0 release target.

## Technical
- Clipboard paste now reasserts the dictation text immediately before Cmd+V.
- Clipboard restore is delayed and skipped if the clipboard changed after paste.
