# Safe completion commands

Run these locally from the project directory after the environment can reach the OpenAI speech endpoint and launch headless Chrome. These commands do not upload anything.

```bash
cd /Users/avysotsky/.codex/worktrees/7c75/whispermate/marketing/videos/2026-07-30-how-to-use-dictation-on-mac
```

## 0. Add a current real Mac product capture

Do not publish a screenshot-based launch video using only the conceptual panels
in this draft. Capture the current shipping Mac app at 1920×1080 or larger,
remove or mask any personal transcript/account data, copy the approved capture
into `public/`, and replace at least one conceptual product panel in
`src/scenes.tsx` with that real capture. Keep the conceptual label on any
remaining simulated text field.

The repository's old `screenshot.png` is intentionally excluded because it
predates the current interface.

## 1. Generate scene-synced narration

The key is read directly at runtime and is not copied into this project or printed.

```bash
python3 /Users/avysotsky/.codex/skills/launch-video/scripts/tts_voiceover.py \
  --scenes scenes.json \
  --out vo \
  --api-key-file /Users/avysotsky/Projects/vood/writingmate.ai/.vercel/.env.production.local \
  --fps 30 \
  --lead-in 0.4 \
  --voice ash \
  --total-seconds 58
```

Every scene must print `OK`. If any scene prints `OVERFLOWS SCENE`, lengthen that scene in `src/theme.ts`, update every affected `start_frame` and `next_start_frame` in `scenes.json`, update `--total-seconds`, then rerun narration before rendering.

## 2. Validate and render the silent 1080p master

```bash
npm install
npm run typecheck
npm run render
```

## 3. Mux the narration without re-encoding the master video

```bash
ffmpeg -y \
  -i out/video-master-silent.mp4 \
  -i vo/voiceover-track.m4a \
  -map 0:v:0 \
  -map 1:a:0 \
  -c:v copy \
  -c:a aac \
  -b:a 192k \
  -shortest \
  out/video-master.mp4
```

## 4. Encode the YouTube review cut

```bash
ffmpeg -y \
  -i out/video-master.mp4 \
  -c:v libx264 \
  -crf 25 \
  -preset slow \
  -pix_fmt yuv420p \
  -movflags +faststart \
  -c:a aac \
  -b:a 160k \
  out/video-yt.mp4
```

Confirm the cut is below 10 MB:

```bash
stat -f '%z bytes' out/video-yt.mp4
```

If it is 10,000,000 bytes or larger, rerun the previous ffmpeg command with `-crf 28` and verify again.

## 5. Final quality checks

```bash
ffprobe -v error \
  -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate \
  -show_entries format=duration,size \
  -of json \
  out/video-master.mp4

ffmpeg -i out/video-yt.mp4 \
  -af volumedetect \
  -f null - 2>&1 | grep -E 'mean_volume|max_volume'
```

Expected: 1920×1080, 30 fps, one H.264 video stream, one AAC audio stream, roughly 58 seconds, mean audio near -15 to -16 dB, maximum below 0 dB, and the review cut below 10 MB.

## 6. Review only

The metadata is preset to `"privacyStatus": "unlisted"` in `youtube-meta.json`, but no upload command is included. Review the master, narration, and thumbnail first. Upload only after explicit approval.
