# Screenshot, narration, render, and upload commands

Run commands from this video directory. Never commit generated media, OAuth material, access tokens, API keys, or a copied environment file.

## 1. Validate the captured evidence

```bash
identify public/*.png
shasum -a 256 public/*.png
```

Inspect every image at original resolution and compare the hashes with `SOURCES.md`. The GitHub pages must remain public, signed-out captures with no account data or secrets.

## 2. Install and validate the Remotion project

```bash
npm install
npm run typecheck
```

Preview representative frames and render the thumbnail:

```bash
npx remotion still src/index.ts OpenSourceSpeechToText out/preview-105.png --frame=105
npx remotion still src/index.ts OpenSourceSpeechToText out/preview-810.png --frame=810
npx remotion still src/index.ts OpenSourceSpeechToText out/preview-1410.png --frame=1410
npm run thumbnail
```

## 3. Generate the emotive, scene-synced voice-over

Point `OPENAI_ENV_FILE` at a local file containing `OPENAI_API_KEY`. Do not copy that file into this project.

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

The launch-video skill uses `gpt-4o-mini-tts` with an emotive instruction prompt. Read the printed durations. If a clip overflows, increase that scene in `src/theme.ts`, update all following start frames in `scenes.json`, and keep the final duration between 45 and 60 seconds.

## 4. Render, mux, encode, and extract poster

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
- thumbnail and poster remain readable at small size.

## 5. Upload unlisted and verify

Set the configured local OAuth paths without printing their contents:

```bash
youtubeuploader \
  -filename out/video-yt.mp4 \
  -secrets "$YOUTUBE_CLIENT_SECRET_JSON" \
  -metaJSON youtube-meta.json \
  -cache "$YOUTUBE_TOKEN_CACHE"
```

Copy the returned ID into `UPLOAD_CHECKLIST.md` and the performance log. Verify the exact upload:

```bash
python3 /Users/avysotsky/.codex/skills/launch-video/scripts/youtube.py status \
  --id "$YOUTUBE_VIDEO_ID" \
  --secrets "$YOUTUBE_CLIENT_SECRET_JSON" \
  --cache "$YOUTUBE_TOKEN_CACHE"
```

The response must show channel `Artem Vysotsky`, channel ID `UCRCOQWtK3JhtR2l2votWazA`, the exact keyword-led title, and privacy `unlisted`. Send the review URL to the user. Never change it to public without explicit approval of this exact video.
