# Open-Source Speech to Text — daily keyword video

- Production date: 2026-08-02
- Primary keyword: `open-source speech to text`
- Research snapshot: 210 US searches/month, keyword difficulty 35
- Target runtime: 60 seconds at 1920×1080, 30 fps
Release gate: unlisted review before any public release

## Why this topic was rotated forward

The scheduled `voice to text Windows` video requires live Windows footage. The current Windows client is WPF, cannot run on this macOS host, and has no current committed screenshots. Rather than reconstruct or reuse stale Windows UI, today’s video pulls forward the distinct `open-source speech to text` intent and proves it against the live public repository.

## Status

Current first-party GitHub captures, the claim-checked script, Remotion composition, emotive narration, 60-second master, upload cut, metadata, provenance ledger, thumbnail, poster, and upload checklist are complete. Generated narration and media are kept untracked.

The first upload (`jV31ppJ4jP4`) exposed a credential mismatch during the required verification step: it landed on `Writingmate: Your All-in-One AI Platform` instead of the configured `Artem Vysotsky` channel. It was immediately changed to private and was never public. The finished cut now waits for a separate OAuth token authenticated to channel ID `UCRCOQWtK3JhtR2l2votWazA`; only then may it be uploaded as unlisted for review. It must never be made public automatically.

## Files

- `public/` — real 1920×1080 public-repository captures made on 2026-08-02.
- `scenes.json` — frame-accurate narration and on-screen intent.
- `voiceover-script.md` — concise, caveat-aware narration.
- `src/` — 1080p Remotion composition and thumbnail still.
- `youtube-meta.json` — keyword-led unlisted metadata.
- `SOURCES.md` — dated claim and visual provenance.
- `RENDER_COMMANDS.md` — screenshot-to-upload commands.
- `UPLOAD_CHECKLIST.md` — channel, metadata, privacy, and approval gates.

Generated media, which must stay untracked:

- `vo/voiceover-track.m4a`
- `out/video-master-silent.mp4`
- `out/video-master.mp4`
- `out/video-yt.mp4` (under 10 MB)
- `out/thumbnail.png`
- `out/poster.jpg`

## Creative direction

The video answers a verification intent rather than presenting another dictation demo. It shows the live public repository, platform folders, MIT License, third-party notices, build instructions, and the README’s offline/cloud boundary. No source file containing credentials is opened, and no website pricing, testimonials, performance claims, customer images, or marketing composites appear.
