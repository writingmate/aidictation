# Capture, narration, render, and upload commands

Run commands from this video directory. Never commit generated media, OAuth material, access tokens, API keys, or a copied environment file.

## 1. Current-product capture gate

Install and open the current Android `0.0.32` build on a clean emulator or test device. Complete the real Accessibility and microphone setup. Use only synthetic text. Capture the four exact files listed in `SOURCES.md`.

```bash
test -f public/current-captures/shot-accessibility-disclosure.png
test -f public/current-captures/shot-field-focused.png
test -f public/current-captures/shot-result.png
test -f public/current-captures/shot-floating-mic.png
```

Inspect every capture at original resolution before continuing. Confirm that `shot-result.png` shows text produced by an actual dictation attempt, not typed or composited text. Fill in the capture ledger in `SOURCES.md`.

## 2. Install and validate the Remotion project

```bash
npm install
npm run typecheck
```

Preview representative frames before the full render:

```bash
npx remotion still src/index.ts VoiceTypingAndroid out/preview-120.png --frame=120
npx remotion still src/index.ts VoiceTypingAndroid out/preview-855.png --frame=855
npx remotion still src/index.ts VoiceTypingAndroid out/preview-1380.png --frame=1380
npm run thumbnail
```

## 3. Generate the emotive, scene-synced voice-over

Point `OPENAI_ENV_FILE` at a local file that contains `OPENAI_API_KEY`. Do not copy that file into this project.

```bash
python3 /Users/avysotsky/.codex/skills/launch-video/scripts/tts_voiceover.py \
  --scenes scenes.json \
  --out vo/ \
  --api-key-file "$OPENAI_ENV_FILE" \
  --fps 30 \
  --lead-in 0.4 \
  --voice ash \
  --total-seconds 60
```

The skill uses `gpt-4o-mini-tts` with an emotive delivery prompt. Read the printed durations. If a clip overflows its scene, increase that scene in `src/theme.ts`, update all following start frames in `scenes.json`, and keep the total between 45 and 60 seconds.

## 4. Render, mux, and encode

```bash
npm run render

ffmpeg -y \
  -i out/video-master-silent.mp4 \
  -i vo/voiceover-track.m4a \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -b:a 192k -shortest \
  out/video-master.mp4

ffmpeg -y \
  -i out/video-master.mp4 \
  -c:v libx264 -crf 25 -preset slow -pix_fmt yuv420p \
  -movflags +faststart \
  -c:a aac -b:a 160k \
  out/video-yt.mp4

ffmpeg -y -ss 3 -i out/video-master.mp4 -frames:v 1 -q:v 3 out/poster.jpg
```

Validate the outputs:

```bash
ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate -of json out/video-master.mp4
ffprobe -v error -show_entries format=duration,size -of json out/video-master.mp4 out/video-yt.mp4
ffmpeg -i out/video-yt.mp4 -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
```

Required checks:

- master and upload cut are 1920×1080 at 30 fps;
- upload cut contains one video and one audio stream;
- duration is no more than 60 seconds;
- mean loudness is near -16 dB and peak is below 0 dB;
- `out/video-yt.mp4` is under 10 MB;
- thumbnail and poster are readable at small size and show only the real current capture.

## 5. Upload unlisted and verify

Set local paths without printing their contents:

```bash
youtubeuploader \
  -filename out/video-yt.mp4 \
  -secrets "$YOUTUBE_CLIENT_SECRET_JSON" \
  -metaJSON youtube-meta.json \
  -cache "$YOUTUBE_TOKEN_CACHE"
```

Copy the returned video ID into `UPLOAD_CHECKLIST.md` and the performance log. Then verify it:

```bash
python3 /Users/avysotsky/.codex/skills/launch-video/scripts/youtube.py status \
  --id "$YOUTUBE_VIDEO_ID" \
  --secrets "$YOUTUBE_CLIENT_SECRET_JSON" \
  --cache "$YOUTUBE_TOKEN_CACHE"
```

The result must show channel `Artem Vysotsky`, channel ID `UCRCOQWtK3JhtR2l2votWazA`, the exact keyword-led title, and privacy `unlisted`. Send the unlisted review URL to the user.

Do not run a privacy change to `public` until the user explicitly approves this exact video.
