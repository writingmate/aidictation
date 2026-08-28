#!/usr/bin/env python3
"""One-take launch announcement video builder.

The fastest way to get over announcement paralysis: record ONE voice take,
point this at a folder of photos/screenshots/screen recordings, and you get
a finished announcement video with Ken Burns motion, crossfades, and your
narration. No editor, no timeline, no excuses.

Typical flow (all on your Mac, only needs ffmpeg — `brew install ffmpeg`):

    # 1. Grab media: in Google Photos select your shots and press Shift+D
    #    (downloads a zip), or drop screenshots/screen recordings in a folder.
    # 2. One command — it records your mic, then builds the video:
    python3 scripts/launch_video.py --media ~/Downloads/launch-shots

    # Or use a Voice Memo / existing narration file instead of recording:
    python3 scripts/launch_video.py --media shots/ --audio narration.m4a

    # Vertical cut for Reels/Shorts/TikTok:
    python3 scripts/launch_video.py --media shots/ --vertical

    # With title and outro cards:
    python3 scripts/launch_video.py --media shots/ \
        --title "AIDictation 0.0.112" --outro "aidictation.com"

Media folder can mix .jpg .jpeg .png .heic .mp4 .mov — items are used in
filename order, so prefix with 01-, 02-, ... to control the story. Photo
slide durations are computed automatically so the video matches the length
of your narration. Videos are muted and trimmed to slide length (hold the
last frame if shorter).

Note on Google Photos API: since March 2025 the Photos Library API only
exposes app-created media, so a proper API integration would need OAuth
setup for basically no benefit. Shift+D in the web UI (or Google Takeout)
is the pragmatic path.
"""

import argparse
import glob
import os
import platform
import shutil
import subprocess
import sys
import tempfile

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".webp"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v"}
FADE = 0.5           # crossfade duration between slides, seconds
MIN_SLIDE = 2.0      # never flash a slide shorter than this
DEFAULT_SLIDE = 3.5  # slide length when there is no narration to match
CARD_DUR = 2.5       # title/outro card duration
TAIL = 1.0           # video keeps rolling this long after narration ends
FPS = 30

MAC_FONTS = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/SFNSDisplay.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    if res.returncode != 0:
        die(f"command failed: {' '.join(cmd)}\n{res.stderr.decode(errors='replace')[-2000:]}")
    return res


def probe_duration(path):
    res = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
               "-of", "default=noprint_wrappers=1:nokey=1", path])
    return float(res.stdout.decode().strip())


def find_font():
    for f in MAC_FONTS:
        if os.path.exists(f):
            return f
    return None


def record_narration(out_path, mic):
    if platform.system() != "Darwin":
        die("mic recording is only wired up for macOS; pass --audio <file> instead")
    print("\nRecording narration. A rough one-take is fine — shipped beats perfect.")
    input("Press Enter to START recording... ")
    print("● Recording — press Enter again to stop.\n")
    proc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "avfoundation", "-i", f":{mic}", "-ac", "1", "-ar", "48000", out_path],
        stdin=subprocess.PIPE)
    try:
        input()
    except KeyboardInterrupt:
        pass
    try:
        proc.stdin.write(b"q")
        proc.stdin.flush()
    except BrokenPipeError:
        pass
    proc.wait()
    if not os.path.exists(out_path) or probe_duration(out_path) < 0.5:
        die("recording came out empty — check mic permission for your terminal "
            "(System Settings > Privacy & Security > Microphone), or list devices with: "
            'ffmpeg -f avfoundation -list_devices true -i ""  and pass --mic <index>')
    print(f"Got {probe_duration(out_path):.1f}s of narration.\n")


def convert_heic(path, workdir, idx):
    out = os.path.join(workdir, f"heic_{idx}.jpg")
    if shutil.which("sips"):
        run(["sips", "-s", "format", "jpeg", path, "--out", out])
        return out
    return path  # let ffmpeg try; some builds decode HEIC


def make_image_clip(src, dur, size, zoom_in, out, workdir_font_unused):
    w, h = size
    frames = max(int(round(dur * FPS)), 2)
    rate = 0.12 / frames
    if zoom_in:
        z = f"min(zoom+{rate:.6f},1.12)"
    else:
        z = f"if(eq(on,1),1.12,max(zoom-{rate:.6f},1.0))"
    vf = (
        # big upscale first so zoompan doesn't jitter
        f"scale={w * 4}:{h * 4}:force_original_aspect_ratio=increase,"
        f"crop={w * 4}:{h * 4},"
        f"zoompan=z='{z}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
        f":d={frames}:s={w}x{h}:fps={FPS},"
        "format=yuv420p"
    )
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
         "-vf", vf, "-t", f"{dur:.3f}", "-r", str(FPS),
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", out])


def make_video_clip(src, dur, size, out):
    w, h = size
    vf = (
        f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},"
        f"fps={FPS},tpad=stop_mode=clone:stop_duration={dur:.3f},"
        f"trim=duration={dur:.3f},setpts=PTS-STARTPTS,format=yuv420p"
    )
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
         "-an", "-vf", vf, "-r", str(FPS),
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", out])


def make_card(text, size, out):
    w, h = size
    font = find_font()
    if not font:
        die("no usable font found for title/outro cards; drop --title/--outro")
    safe = text.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\\\\\'")
    vf = (
        f"drawtext=fontfile={font}:text='{safe}':fontcolor=white"
        f":fontsize={h // 12}:x=(w-text_w)/2:y=(h-text_h)/2,"
        "format=yuv420p"
    )
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", f"color=c=0x111111:s={w}x{h}:d={CARD_DUR}:r={FPS}",
         "-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", out])


def collect_media(folder, workdir):
    items = []
    for path in sorted(glob.glob(os.path.join(folder, "*"))):
        ext = os.path.splitext(path)[1].lower()
        if ext in IMAGE_EXTS or ext in VIDEO_EXTS:
            items.append((path, "video" if ext in VIDEO_EXTS else "image"))
    converted = []
    for i, (path, kind) in enumerate(items):
        if kind == "image" and path.lower().endswith(".heic"):
            path = convert_heic(path, workdir, i)
        converted.append((path, kind))
    return converted


def main():
    p = argparse.ArgumentParser(description="Record one take, get a launch video.")
    p.add_argument("--media", required=True, help="folder of photos/videos (used in filename order)")
    p.add_argument("--audio", help="existing narration file; if omitted, records your mic")
    p.add_argument("--out", default="announcement.mp4", help="output file (default announcement.mp4)")
    p.add_argument("--title", help="optional opening title card text")
    p.add_argument("--outro", help="optional closing card text (e.g. a URL)")
    p.add_argument("--vertical", action="store_true", help="1080x1920 for Reels/Shorts instead of 1920x1080")
    p.add_argument("--music", help="optional background music file, mixed quietly under narration")
    p.add_argument("--mic", default="0", help="avfoundation audio device index (default 0)")
    p.add_argument("--keep-temp", action="store_true", help="keep intermediate clips for debugging")
    args = p.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            die(f"{tool} not found — install it with: brew install ffmpeg")
    if not os.path.isdir(args.media):
        die(f"media folder not found: {args.media}")

    size = (1080, 1920) if args.vertical else (1920, 1080)
    workdir = tempfile.mkdtemp(prefix="launch_video_")
    try:
        media = collect_media(args.media, workdir)
        if not media:
            die(f"no photos or videos found in {args.media} "
                f"(looked for {', '.join(sorted(IMAGE_EXTS | VIDEO_EXTS))})")
        print(f"Found {len(media)} media item(s) in {args.media}")

        narration = args.audio
        if narration:
            if not os.path.exists(narration):
                die(f"audio file not found: {narration}")
        else:
            narration = os.path.join(workdir, "narration.wav")
            record_narration(narration, args.mic)
        narration_dur = probe_duration(narration)

        # Slide length: spread the narration (plus a breathing tail) across
        # the flexible slides, accounting for crossfade overlap and cards.
        n_cards = (1 if args.title else 0) + (1 if args.outro else 0)
        n_clips = len(media) + n_cards
        fixed = n_cards * CARD_DUR
        target_total = (CARD_DUR if args.title else 0) + narration_dur + TAIL + (CARD_DUR if args.outro else 0)
        overlap = FADE * (n_clips - 1)
        slide = (target_total + overlap - fixed) / len(media) if narration_dur else DEFAULT_SLIDE
        slide = max(slide, MIN_SLIDE)

        print(f"Narration {narration_dur:.1f}s -> {len(media)} slides @ {slide:.1f}s each")

        clips = []
        if args.title:
            card = os.path.join(workdir, "card_title.mp4")
            make_card(args.title, size, card)
            clips.append((card, CARD_DUR))
        for i, (path, kind) in enumerate(media):
            out = os.path.join(workdir, f"clip_{i:03d}.mp4")
            print(f"  [{i + 1}/{len(media)}] {os.path.basename(path)}")
            if kind == "image":
                make_image_clip(path, slide, size, zoom_in=(i % 2 == 0), out=out,
                                workdir_font_unused=None)
            else:
                make_video_clip(path, slide, size, out)
            clips.append((out, slide))
        if args.outro:
            card = os.path.join(workdir, "card_outro.mp4")
            make_card(args.outro, size, card)
            clips.append((card, CARD_DUR))

        # Chain crossfades. Video length = sum(durations) - FADE*(n-1).
        total = sum(d for _, d in clips) - FADE * (len(clips) - 1)
        inputs = []
        for path, _ in clips:
            inputs += ["-i", path]
        inputs += ["-i", narration]
        narr_idx = len(clips)
        music_idx = None
        if args.music:
            inputs += ["-i", args.music]
            music_idx = narr_idx + 1

        filters = []
        if len(clips) == 1:
            filters.append(f"[0:v]copy[vout]")
        else:
            prev = "[0:v]"
            offset = 0.0
            for i in range(1, len(clips)):
                offset += clips[i - 1][1] - FADE
                label = "[vout]" if i == len(clips) - 1 else f"[vx{i}]"
                filters.append(
                    f"{prev}[{i}:v]xfade=transition=fade:duration={FADE}"
                    f":offset={offset:.3f}{label}")
                prev = label

        delay_ms = int(CARD_DUR * 1000) if args.title else 0
        fade_start = max(total - 0.8, 0)
        narr_chain = (f"[{narr_idx}:a]aformat=sample_rates=48000:channel_layouts=stereo,"
                      f"adelay={delay_ms}|{delay_ms},apad[an]")
        filters.append(narr_chain)
        if music_idx is not None:
            filters.append(
                f"[{music_idx}:a]aformat=sample_rates=48000:channel_layouts=stereo,"
                f"volume=0.12,apad[am]")
            filters.append("[an][am]amix=inputs=2:duration=first:normalize=0[amix]")
            aout_src = "[amix]"
        else:
            aout_src = "[an]"
        filters.append(f"{aout_src}afade=t=out:st={fade_start:.3f}:d=0.8[aout]")

        print("Stitching final video...")
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs,
             "-filter_complex", ";".join(filters),
             "-map", "[vout]", "-map", "[aout]",
             "-t", f"{total:.3f}",
             "-c:v", "libx264", "-preset", "medium", "-crf", "19",
             "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
             args.out])
        print(f"\nDone: {args.out} ({total:.1f}s, {size[0]}x{size[1]})")
        print("Watch it once, then post it. Don't re-record more than once.")
        if platform.system() == "Darwin":
            subprocess.run(["open", args.out])
    finally:
        if args.keep_temp:
            print(f"intermediates kept in {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
