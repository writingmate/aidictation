# AIDictation v0.0.65

## Improvements
- Adds a simple overlay color picker in onboarding and Settings.
- Keeps the app primary color orange while letting the recording overlay use the selected color.
- Improves onboarding permission steps with clearer copy and drag-and-drop guidance for macOS privacy settings.
- Prevents Fn onboarding checks from triggering extra macOS permission prompts.

## Fixes
- Avoids changing native Settings controls, sidebars, and app-wide tint when the overlay color changes.
- Keeps overlay color changes stable when selected from the Settings menu.

## Technical
- Embeds PermissionFlow behind a macOS 13+ runtime bridge so the main app can keep macOS 12 compatibility.
- Bumps macOS app version to 0.0.65.
