---
name: bilibili-downloader
description: Download videos and audio from Bilibili (B站). Use when the user wants to download, save, or extract content from Bilibili videos — including audio (MP3), video (MP4), thumbnails, or any combination. Also handles batch downloading by UP主, keyword, or playlist. Triggers on mentions of B站, bilibili, BV号, UP主, 下载视频, 下载音频, 批量下载, or any request to save Bilibili content locally.
---

# Bilibili Downloader

Download videos, audio, thumbnails, or any combination from Bilibili, with automatic catalog generation.

## Prerequisites

Verify these tools are available. Install any that are missing:

```bash
# Required
which yt-dlp || brew install yt-dlp
which ffmpeg || brew install ffmpeg

# Recommended (fallback when yt-dlp fails)
which you-get || pip install you-get
```

## Critical: Bilibili 412 Error (WBI Signature)

Bilibili uses WBI signature verification on its playurl API. **Even with browser cookies, yt-dlp may still get 412 errors** — Bilibili frequently updates their WBI algorithm, and yt-dlp may lag behind.

**The bundled script `scripts/bili-dl.sh` has a multi-strategy fallback chain:**
1. yt-dlp with each available browser's cookies (tried sequentially)
2. you-get (up to 720P, no login needed, works even when yt-dlp fails)
3. yt-dlp without cookies (last resort)

Always prefer using the script over raw commands.

## Workflow

### Step 1: Parse user request

Identify from the user's message:
- **Source**: BV number(s), Bilibili URL(s), UP主 name + keyword, or a Bilibili playlist/collection URL
- **Content type**: what to download (see options below)
- **Output directory**: where to save files (default: current directory)

If the user doesn't specify content type, **ask them**. Don't assume.

### Step 2: Content type options

Present these options to the user if they haven't specified:

| Option | Flag | What it does |
|--------|------|-------------|
| Audio only | `audio` | Extract audio as MP3 (highest quality) with embedded thumbnail |
| Video only | `video` | Download best available video, merged with audio |
| Video + Audio | `video+audio` | Download video and extract audio as separate MP3 |
| Thumbnail | `thumbnail` | Save cover image only (JPG/PNG) |
| All | `all` | Video + Audio + Thumbnail |

Default quality: best available without premium login. If the user has a Bilibili premium account and wants higher quality (4K/1080P high bitrate), use `--cookies-from-browser <browser>` (this is already default in the script, but premium quality requires the user to actually be logged into that browser with a premium account).

### Step 3: Resolve video list

How to find videos depends on what the user provides:

**A. Direct BV number(s) or URL(s)**
Use as-is. The user might give one or many.

**B. UP主 + keyword search**
When the user says "download all X videos from UP主 Y", you need to find the video list:

1. **Web search first** — Search `"<UP主名>" "<关键词>" site:bilibili.com/video` to find BV numbers. This is the most reliable method because Bilibili's own search API often requires WBI signatures or returns captchas.
2. **Fallback: related-videos API** — Use `/x/web-interface/archive/related?bvid=BVxxx` to traverse recommendations, filtering by the same UP主 and keyword match.
3. **Fallback: Bilibili search** — The search API (`/x/web-interface/search/type`) often requires WBI signature. Use only if other methods fail.
4. Deduplicate by BV number.

**C. Bilibili collection/playlist URL**
Use yt-dlp's `--flat-playlist` with cookies to enumerate videos.

### Step 4: Download using the bundled script

The script at `scripts/bili-dl.sh` handles multi-tool fallback, format conversion, filename sanitization, and skip-if-exists automatically.

```bash
SCRIPT="<skill-dir>/scripts/bili-dl.sh"

# Get metadata first (includes charged video detection)
bash "$SCRIPT" metadata "BV1FF68YoEKB" "/output/dir"

# Download audio
bash "$SCRIPT" audio "BV1FF68YoEKB" "/output/dir" "视频标题"

# Download video
bash "$SCRIPT" video "BV1FF68YoEKB" "/output/dir" "视频标题"

# Download video + audio
bash "$SCRIPT" video+audio "BV1FF68YoEKB" "/output/dir" "视频标题"

# Download thumbnail
bash "$SCRIPT" thumbnail "BV1FF68YoEKB" "/output/dir" "视频标题"
```

**For batch downloads** (multiple BV numbers), run downloads sequentially with a small delay to avoid rate limiting:

```bash
for bvid in BV1xxx BV1yyy BV1zzz; do
    bash "$SCRIPT" audio "$bvid" "/output/dir"
    sleep 2
done
```

**If you prefer not using the script**, the recommended order is:
1. Try yt-dlp with cookies
2. If 412, fall back to you-get
3. If you-get downloads FLV, convert with ffmpeg

```bash
# yt-dlp (try with cookies)
PYTHONIOENCODING=utf-8 yt-dlp --cookies-from-browser safari --proxy "" \
    -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" \
    --merge-output-format mp4 \
    -o "$DIR/%(title)s.%(ext)s" \
    "https://www.bilibili.com/video/$bvid/"

# you-get fallback (if yt-dlp fails)
PYTHONIOENCODING=utf-8 you-get -o "$DIR" "https://www.bilibili.com/video/$bvid/"
# Convert FLV to MP4 if needed
ffmpeg -i "$DIR/title.flv" -c copy "$DIR/title.mp4"
```

### Step 5: Generate catalog

After all downloads complete, fetch metadata via the Bilibili API (not yt-dlp, to avoid 412) and create/update the catalog file at `<output_directory>/catalog.csv`.

Get metadata from Bilibili API:

```bash
# Use /usr/bin/curl directly to bypass any proxies (e.g. rtk)
/usr/bin/curl -s "https://api.bilibili.com/x/web-interface/view?bvid=$bvid" | \
  python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
if d.get('code') == 0:
    v = d['data']
    print(f\"{v['bvid']},{v['title']},{v['owner']['name']},{v['duration']}\")
"
```

The catalog CSV must have these columns:

```
BV号,标题,UP主,时长(秒),下载类型,文件名,下载时间
BV1dh4y1L7eS,血色序章：第一次世界大战是怎么爆发的,瑞克Zero,1523,audio,血色序章：第一次世界大战是怎么爆发的.mp3,2026-04-22
```

### Step 6: Summary

Report to the user:
- Total files downloaded
- Total size on disk
- Catalog file location
- Any failures (with BV numbers so they can retry)
- Quality note (e.g. "Downloaded at 720P via you-get fallback")

## Edge cases

- **412 Precondition Failed**: Bilibili's WBI signature rejection. The script automatically falls back through: yt-dlp+cookies (each browser) → you-get → yt-dlp no cookies. Do NOT retry the same failed approach.
- **Cookie extraction failure**: If `--cookies-from-browser` fails (e.g., browser profile locked, no Bilibili cookies), the script tries the next browser automatically.
- **you-get quality**: you-get supports up to 720P without login cookies. For higher quality, the user needs to export cookies: `you-get --cookies cookies.txt ...`
- **Charged/Premium-exclusive videos** (`is_upower_exclusive: true`): These are paid videos. The metadata command will flag them. They can still be downloaded at lower quality (e.g. 720P) without payment, but higher quality requires purchase + login cookies.
- **FLV output**: you-get may download in FLV format. The script automatically converts FLV→MP4 using ffmpeg.
- **Rate limiting**: Bilibili may rate-limit after ~20 rapid requests even with cookies. Add `sleep 2` between batch downloads. For yt-dlp, use `--sleep-requests 2`.
- **Multi-part videos**: Some BV numbers contain multiple episodes (分P). Use `--flat-playlist` first to check, then download each part.
- **Deleted/unavailable videos**: Skip and report in the summary.
- **Filename conflicts**: Append BV number to filename if titles collide.
- **Proxy interference**: If yt-dlp/curl is configured with a proxy (e.g. rtk), it may cause 412 or connection errors. The script uses `--proxy ""` for yt-dlp and `/usr/bin/curl` to bypass.

## Reference files

- `references/bilibili-api.md` — Bilibili API endpoints for video discovery and metadata
- `scripts/bili-dl.sh` — Download helper with multi-tool fallback
