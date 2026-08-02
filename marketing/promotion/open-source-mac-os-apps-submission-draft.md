# `open-source-mac-os-apps` Submission Draft

Target: [`serhii-londar/open-source-mac-os-apps`](https://github.com/serhii-londar/open-source-mac-os-apps)

Status: **deferred and not submitted**. On August 2, 2026, the target's current
`applications.json` failed strict JSON parsing because of an existing trailing
comma. [PR #1230](https://github.com/serhii-londar/open-source-mac-os-apps/pull/1230)
attempts to repair the base file. Recheck after that repair merges; do not claim
whole-file local validation before then.

Proposed branch: `codex/add-ai-dictation`

Proposed pull request title: `Add AI Dictation`

## `applications.json` Entry

```json
{
  "short_description": "MIT-licensed voice-to-text client for macOS with offline recognition on supported devices, optional cloud cleanup, and configurable shortcuts.",
  "categories": [
    "productivity"
  ],
  "repo_url": "https://github.com/writingmate/aidictation",
  "title": "AI Dictation",
  "icon_url": "https://raw.githubusercontent.com/writingmate/aidictation/main/Whishpermate/Whispermate/Assets.xcassets/AppIcon.appiconset/512-mac.png",
  "screenshots": [
    "https://raw.githubusercontent.com/writingmate/aidictation/main/screenshot.png"
  ],
  "official_site": "https://aidictation.com",
  "languages": [
    "swift"
  ]
}
```

Insert the entry at the correct alphabetical position in the current
`applications` array after rereading the latest contribution guide.

## Pull Request Body

```markdown
## Project URL

https://github.com/writingmate/aidictation

## Category

Productivity

## Description

Adds AI Dictation, an MIT-licensed voice-to-text client for macOS with offline
recognition on supported devices, optional cloud cleanup, and configurable
shortcuts.

## Why it should be included to `Awesome macOS open source applications` (optional)

AI Dictation is a native Swift macOS productivity app with recent development,
a clear English README, published source, a project website, an icon, a
screenshot, and an MIT license.

## Disclosure

This is a self-submission by the AI Dictation project owner/team. AI assistance
was used to review the contribution rules, prepare the JSON entry, validate its
fields, and draft this pull request. The URLs and product claims were checked
against the project repository.

## Checklist

- [x] Edited `applications.json` instead of `README.md`.
- [x] Only one project/change is in this pull request.
- [x] Added the available screenshot.
- [x] The project has a commit from less than two years ago.
- [x] The project has a clear README in English.
- [x] The project is licensed under the MIT License.
```

## Entry-only validation completed

- JSON shape and punctuation
- `productivity` category and `swift` language
- HTTPS repository, website, icon, and screenshot URLs
- Description ends with a period
- No trailing whitespace

The proposed object is structurally valid in isolation. The target file is not
currently valid strict JSON, so whole-file validation and publication remain
blocked. Recheck all rules and the current insertion location after the base
repair merges.
