# Unlisted YouTube upload checklist

## Expected destination

- Channel title: `Artem Vysotsky`
- Channel ID: `UCRCOQWtK3JhtR2l2votWazA`
- Category: Science & Technology (`28`)
- Initial privacy: `unlisted`
- Public release: blocked until the user approves this exact upload

## Pre-upload

- [ ] Current Android `0.0.32` capture ledger is complete in `SOURCES.md`.
- [ ] All screenshots contain synthetic content and no notifications, customer data, account details, or secrets.
- [ ] `shot-result.png` came from a real dictation attempt.
- [ ] Narration clips fit their scenes without overlap.
- [ ] Master is 1920×1080, 30 fps, no more than 60 seconds, with audible narration.
- [ ] Upload cut is under 10 MB and uses fast-start encoding.
- [ ] Audio mean is near -16 dB and maximum is below 0 dB.
- [ ] Thumbnail and poster use the real current UI and contain no stale claims.
- [x] A brand-only thumbnail/poster candidate exists without stale or fabricated UI; replace it with the Remotion still after current UI capture.
- [x] Title begins with the target keyword: `Voice Typing Android`.
- [x] Description links to <https://aidictation.com> and <https://github.com/writingmate/aidictation>.
- [x] Metadata privacy is `unlisted`.

## Post-upload verification

- Video ID: pending
- Unlisted URL: pending
- Upload time: pending

- [ ] Status response says `Artem Vysotsky`.
- [ ] Status response says channel ID `UCRCOQWtK3JhtR2l2votWazA`.
- [ ] Status response says `unlisted`.
- [ ] YouTube title exactly matches `youtube-meta.json`.
- [ ] Both project links are clickable in the description.
- [ ] Video and audio play through the final CTA.
- [ ] Mobile thumbnail crop remains readable.
- [ ] User has received the unlisted review link.
- [ ] User has explicitly approved the exact video.

Only after every item above is complete may a separate, user-approved action change the video to public.

## Current production blocker — 2026-08-01

The current execution safety gate prevents the networked voice-generation and headless rendering/upload workflow from completing in this run. Do not bypass or retry the rejected route. Preserve the finished source package and resume the media steps when the gate is available or the user grants informed authorization.
