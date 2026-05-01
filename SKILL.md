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
```

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
| Video only | `video` | Download best available video (no audio extraction) |
| Video + Audio | `both` | Download video and extract audio as separate MP3 |
| Thumbnail | `thumbnail` | Save cover image only (JPG/PNG) |
| All | `all` | Video + Audio + Thumbnail |

Default quality: best available without premium login. If the user has a Bilibili premium account and wants higher quality, use `--cookies-from-browser chrome` (or their browser).

### Step 3: Resolve video list

How to find videos depends on what the user provides:

**A. Direct BV number(s) or URL(s)**
Use as-is. The user might give one or many.

**B. UP主 + keyword search**
When the user says "download all X videos from UP主 Y", you need to find the video list:

1. First, find the UP主's UID by searching `https://space.bilibili.com/` or using web search
2. Then find relevant videos using the Bilibili API's related-video endpoint or web search
3. The related-video API (`/x/web-interface/archive/related?bvid=BVxxx`) is the most reliable way to discover videos in a series — start from one known video and traverse recommendations, filtering by the same UP主 and keyword match
4. Deduplicate by BV number

**C. Bilibili collection/playlist URL**
Use yt-dlp's `--flat-playlist` to enumerate videos.

### Step 4: Download

Create a download script dynamically based on the user's choices. Here's the pattern:

```bash
#!/bin/bash
DIR="<output_directory>"
CATALOG="$DIR/catalog.csv"

# Initialize catalog
echo "BV号,标题,UP主,时长(秒),下载类型,文件名,下载时间" > "$CATALOG"

download_audio() {
    local bvid=$1 title=$2
    PYTHONIOENCODING=utf-8 yt-dlp \
        -x --audio-format mp3 --audio-quality 0 --embed-thumbnail \
        -o "$DIR/${title}.%(ext)s" \
        "https://www.bilibili.com/video/$bvid/" 2>&1
}

download_video() {
    local bvid=$1 title=$2
    PYTHONIOENCODING=utf-8 yt-dlp \
        -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" \
        --embed-thumbnail \
        -o "$DIR/${title}.%(ext)s" \
        "https://www.bilibili.com/video/$bvid/" 2>&1
}

download_thumbnail() {
    local bvid=$1 title=$2
    PYTHONIOENCODING=utf-8 yt-dlp \
        --write-thumbnail --skip-download \
        -o "$DIR/${title}" \
        "https://www.bilibili.com/video/$bvid/" 2>&1
}
```

For each video, after downloading, append a row to `catalog.csv`:

```bash
# Get metadata and append to catalog
PYTHONIOENCODING=utf-8 yt-dlp -j "https://www.bilibili.com/video/$bvid/" 2>/dev/null | \
  python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(f\"$bvid,{d.get('title','')},{d.get('uploader','')},{d.get('duration','')},$type,{d.get('title','')}.mp3,$(date +%Y-%m-%d)\")
" >> "$CATALOG"
```

**Important yt-dlp notes:**
- Always set `PYTHONIOENCODING=utf-8` to avoid encoding errors with Chinese characters
- Sanitize filenames: remove `/\:*?"<>|` from titles
- Skip already-downloaded files: check if output exists before downloading
- For large batches (10+), run the download script in the background and monitor progress

### Step 5: Generate catalog

After all downloads complete, create/update the catalog file at `<output_directory>/catalog.csv`.

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

## Edge cases

- **Rate limiting**: Bilibili may rate-limit after ~20 rapid requests. If downloads start failing with 412 errors, add `--sleep-requests 2` to slow down.
- **Premium content**: Some videos require login. Use `--cookies-from-browser <browser>` if the user has a premium account.
- **Multi-part videos**: Some BV numbers contain multiple episodes (分P). Use `--flat-playlist` first to check, then download each part.
- **Deleted/unavailable videos**: Skip and report in the summary.
- **Filename conflicts**: Append BV number to filename if titles collide.

## Reference files

- `references/bilibili-api.md` — Bilibili API endpoints for video discovery and metadata
