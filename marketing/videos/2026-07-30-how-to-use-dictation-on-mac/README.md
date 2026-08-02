# How to Use Dictation on Mac (Built-In + AI)

Remotion pilot for a 1080p, 30 fps, 45–60 second keyword video. The project uses current AI Dictation assets copied from this repository and sourced claims documented in `SOURCES.md`.

## Current status

- Source, scene copy, 139-word narration, metadata, claims notes, and a 1920×1080 thumbnail/poster are complete.
- `npm run typecheck` passes.
- A current real Mac product capture is still required before publication. The
  repository's existing Mac screenshot predates the current interface, so this
  draft uses clearly labeled conceptual motion graphics instead of presenting
  stale UI as current.
- The narrated master and YouTube cut still need a render in an environment allowed to launch headless Chrome and reach the OpenAI speech endpoint. The current Codex sandbox denied both operations before any audio or video was produced.

## Files

- `voiceover-script.md` — human-readable narration.
- `scenes.json` — scene timing, on-screen copy, and TTS input.
- `youtube-meta.json` — YouTube SEO metadata, preset to unlisted.
- `SOURCES.md` — claim-by-claim evidence and visual provenance.
- `RENDER_COMMANDS.md` — exact local TTS, render, mux, encode, and validation commands; no upload.
- `out/thumbnail.png` — 1920×1080 PNG thumbnail candidate.
- `out/poster.jpg` — flattened 8-bit JPEG poster candidate.
- `out/video-master.mp4` — narrated 1080p master.
- `out/video-yt.mp4` — compressed YouTube review cut under 10 MB.

## Build

```bash
npm install
npm run typecheck
npm run thumbnail
npm run render
```

Voice-over is generated with the launch-video skill’s `tts_voiceover.py`, scene-synced from `scenes.json`, then muxed and encoded with ffmpeg. Do not upload directly from this project: the review flow is unlisted first, followed by explicit approval before public release.
