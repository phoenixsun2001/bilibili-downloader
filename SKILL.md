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

Bilibili uses WBI signature verification on its playurl API. **yt-dlp very frequently gets `HTTP Error 412: Precondition Failed`** when fetching video formats, even when:
- the latest yt-dlp is installed (verified: yt-dlp 2026.06.9 still 412s as of 2026-07), and
- valid browser cookies (safari/chrome) are extracted successfully.

Bilibili updates its WBI/playurl algorithm often and yt-dlp's extractor lags behind. **Do not waste cycles retrying yt-dlp or upgrading it expecting a fix** — treat 412 as the expected outcome and rely on the you-get fallback instead.

**Policy: anonymous (cookieless) downloads.** The script NEVER uses `--cookies-from-browser` and you should not pass cookies either. Public videos download fine anonymously; videos that gate their stream behind login/payment are detected and **skipped** (see "Charged/Premium-exclusive videos" below). This also avoids the macOS Keychain hang that `--cookies-from-browser chrome` triggers.

**The bundled script `scripts/bili-dl.sh` fallback chain (all cookieless):**
1. **Charged-video check** → if `is_upower_exclusive`, print `[CHARGED] SKIP: ...` and exit 0 without downloading (no wasted 15-min preview).
2. **you-get (anonymous; up to 480P/720P depending on the video) — the reliable path.**
3. yt-dlp cookieless (best-effort; usually 412s, kept as a last resort).

Always prefer using the script over raw commands.

> **Practical note (2026-07):** For a public video, step 1 passes and step 2 (you-get) downloads the file. yt-dlp's 412 is expected noise. For a charged video, step 1 skips cleanly — capture the `[CHARGED] SKIP` line and record it in the catalog as skipped (see Step 5).

## Critical: you-get needs DASH format names

Bilibili changed its stream IDs to **DASH** format. `you-get -i` now lists formats like:

```
- format:        dash-flv480-AVC        # <resolution>-<codec>
- format:        dash-flv360-HEVC
- format:        dash-flv1080-AV1
```

The legacy names (`flv480`, `flv720`, `mp4`, `mp4hd`, ...) **no longer exist** for most videos. Passing a stale name makes you-get abort with:

```
you-get: [error] oops, something went wrong.
```

**Rules:**
- Always pass the **exact** format string *including the codec suffix* (e.g. `dash-flv480-AVC`, not `dash-flv480`). A bare prefix is NOT accepted.
- Codec preference: **AVC** (most compatible) > HEVC > AV1.
- Resolution preference: 1080 > 720 > 480 > 360 (higher tiers need login cookies for some videos).
- The bundled `bili-dl.sh` already handles this in `you_get_best_format()` — prefer the script over hand-rolled you-get commands.

If you call you-get manually, first list formats then pick one verbatim:

```bash
PYTHONIOENCODING=utf-8 you-get -i "https://www.bilibili.com/video/$bvid/"   # list available formats
PYTHONIOENCODING=utf-8 you-get --format=dash-flv480-AVC -o "$DIR" "https://www.bilibili.com/video/$bvid/"
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
1. Try yt-dlp with cookies (expect 412 on many recent videos — see above)
2. Fall back to you-get with an explicit DASH format (see "you-get needs DASH format names")
3. DASH downloads come out as MP4 already; only convert if you actually get an FLV

```bash
# yt-dlp (try with cookies — often 412s)
PYTHONIOENCODING=utf-8 yt-dlp --cookies-from-browser safari --proxy "" \
    -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" \
    --merge-output-format mp4 \
    -o "$DIR/%(title)s.%(ext)s" \
    "https://www.bilibili.com/video/$bvid/"

# you-get fallback (if yt-dlp fails) — pick a format from `you-get -i` first
PYTHONIOENCODING=utf-8 you-get --format=dash-flv480-AVC -o "$DIR" \
    "https://www.bilibili.com/video/$bvid/"
# Extract audio as MP3 from the downloaded MP4
ffmpeg -i "$DIR/title.mp4" -vn -acodec libmp3lame -q:a 0 "$DIR/title.mp3"
# (Only if you somehow got an FLV) ffmpeg -i "$DIR/title.flv" -c copy "$DIR/title.mp4"
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
- **No cookies / no Keychain**: The script is cookieless by policy — it never calls `--cookies-from-browser`, so there is no cookie extraction to fail and no macOS Keychain prompt to hang on. Don't add `--cookies-from-browser` to "fix" a download; if a video won't yield a full stream anonymously, it's almost certainly charged/login-gated and should be skipped.
- **you-get quality**: Without login, DASH streams typically cap at **480P** (`dash-flv480-*`; some videos offer 360P only). 720P/1080P usually require login cookies: `you-get --cookies cookies.txt ...`. Always confirm what's actually available with `you-get -i` first.
- **you-get "oops, something went wrong"**: This is almost always a **stale format name**. Bilibili now uses DASH IDs like `dash-flv480-AVC`; the legacy `flv480`/`mp4` names no longer exist. Re-run `you-get -i` and pass an exact DASH format string *with codec suffix*. The bundled script's `you_get_best_format()` already does this.
- **Charged/Premium-exclusive videos** (`is_upower_exclusive: true`) — **auto-skipped by the script.** These paid (充电专属) videos gate the full stream behind payment: the playurl API returns only a ~900–930s (~15-min) preview regardless of quality or `fnval` (verified via WBI-signed calls; all return `durl` capped at ~930s, never `dash`). The script checks `is_upower_exclusive` *before* any download attempt, prints `[CHARGED] SKIP: ...`, and writes no file. Record these in the catalog with `下载类型=skipped-charged`. Full download is impossible without paying the UP主, and per the cookieless policy we do not attempt cookie-based workarounds.
- **DASH/FLV output**: Modern DASH downloads come out as **MP4** directly (video+audio already muxed). FLV output is now rare; the script converts FLV→MP4 with ffmpeg only if an FLV actually appears.
- **Login-gated non-charged videos (rare)**: Occasionally a non-charged video exposes only legacy FLV (no DASH) and serves a truncated ~15-min preview anonymously. Under the cookieless policy we don't chase these with login cookies — treat them as undownloadable and skip (optionally note in the catalog as `skipped-logingated`).
- **Rate limiting**: Bilibili may rate-limit after ~20 rapid requests even with cookies. Add `sleep 2` between batch downloads. For yt-dlp, use `--sleep-requests 2`.
- **Multi-part videos**: Some BV numbers contain multiple episodes (分P). Use `--flat-playlist` first to check, then download each part.
- **Deleted/unavailable videos**: Skip and report in the summary.
- **Filename conflicts**: Append BV number to filename if titles collide.
- **Proxy interference**: If yt-dlp/curl is configured with a proxy (e.g. rtk), it may cause 412 or connection errors. The script uses `--proxy ""` for yt-dlp and `/usr/bin/curl` to bypass.

## Reference files

- `references/bilibili-api.md` — Bilibili API endpoints for video discovery and metadata
- `scripts/bili-dl.sh` — Download helper with multi-tool fallback
