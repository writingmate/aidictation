# Unlisted YouTube upload checklist

## Expected destination

- Channel title: `Artem Vysotsky`
- Channel ID: `UCRCOQWtK3JhtR2l2votWazA`
- Category: Science & Technology (`28`)
- Initial privacy: `unlisted`
- Public release: blocked until the user approves this exact upload

## Pre-upload

- [x] Every product claim maps to current first-party evidence in `SOURCES.md`.
- [x] Visuals are current signed-out repository captures with no customer data, secrets, or fabricated UI.
- [x] Title begins with `Open-Source Speech to Text`.
- [x] Description links to <https://aidictation.com> and <https://github.com/writingmate/aidictation>.
- [x] Metadata privacy is `unlisted`.
- [x] Narration clips fit their scenes without overlap.
- [x] Master is 1920×1080, 30 fps, no more than 60 seconds, with audible narration.
- [x] Upload cut is under 10 MB and uses fast-start encoding.
- [x] Audio mean is near -16 dB and maximum is below 0 dB.
- [x] Thumbnail and poster are readable and contain no stale claims.

Artifact QA completed on 2026-08-02:

- Master: 60.000 seconds, 1920×1080, 30 fps, H.264 + AAC, SHA-256 `549bc8efa792553f3e22cd4ee87f8d6cbb2abb3bde5929a5e58c07ff9e6e0acd`.
- Upload cut: 7,994,771 bytes, fast-start H.264 + AAC, SHA-256 `65ab5cc8350a94c99779472fbc2e7eb91cfd805d07910f60eb27c65513f5e1d9`.
- Audio: -16.6 dB mean; -1.4 dB maximum on the upload cut.
- Full decode passed without stream errors; representative frames from all seven scenes were inspected.

## Post-upload verification

- Correct-channel video ID: pending
- Correct-channel unlisted URL: pending
- Verification time: 2026-08-02T14:53:10Z

Blocked upload audit:

- Video `jV31ppJ4jP4` uploaded to `Writingmate: Your All-in-One AI Platform`, not the required `Artem Vysotsky` channel.
- The mismatched upload was changed to `private` immediately after verification and was never public.
- The current OAuth cache must not be reused for the review upload. Authenticate the intended Artem Vysotsky channel into a separate token cache, verify channel ID `UCRCOQWtK3JhtR2l2votWazA`, then upload this exact cut as unlisted with `out/thumbnail.png`.

- [ ] Status response says `Artem Vysotsky`.
- [ ] Status response says channel ID `UCRCOQWtK3JhtR2l2votWazA`.
- [ ] Status response says `unlisted`.
- [x] Mismatched private upload title exactly matches `youtube-meta.json`.
- [ ] Website and GitHub links are clickable in the description.
- [x] Local upload cut video and audio play through the final CTA.
- [x] Thumbnail candidate remains readable at a reduced preview size.
- [ ] User has received the unlisted review link.
- [ ] User has explicitly approved the exact video.

Only after every item above is complete may a separate, user-approved action change the video to public.
