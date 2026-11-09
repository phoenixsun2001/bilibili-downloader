#!/bin/bash
# bili-dl.sh — Bilibili download helper with multi-tool fallback
# Usage: bili-dl.sh <mode> <bvid> <output_dir> [title]
# Modes: audio, video, video+audio, thumbnail, metadata
#
# Download strategy (tried in order), all cookieless/anonymous:
#   audio mode:
#     1. Audio-only direct path (bili-audio-only.py): `you-get -u` extracts the
#        audio-stream URL, curl downloads just the .m4s (~60% less data, stall-proof,
#        full speed). THE reliable audio path since 2026-10.
#     2. you-get full format + ffmpeg extract (fallback; wrapped in a hang watchdog)
#     3. yt-dlp (usually 412s; last resort)
#   video modes:
#     1. yt-dlp (usually 412s on Bilibili's WBI playurl)
#     2. you-get (up to 480P/720P without login)

set -euo pipefail

MODE="${1:?Usage: bili-dl.sh <mode> <bvid> <output_dir> [title]}"
BVID="${2:?Missing BV number}"
OUTDIR="${3:?Missing output directory}"
TITLE="${4:-}"

URL="https://www.bilibili.com/video/$BVID/"

mkdir -p "$OUTDIR"

# Use system curl directly to bypass rtk or other proxies
CURL="/usr/bin/curl"
if [[ ! -x "$CURL" ]]; then
    CURL="curl"
fi

# --- Sanitize filename ---
sanitize_title() {
    echo "$1" | tr '/\:*?"<>|' '_'
}

# --- Get metadata via Bilibili API ---
get_metadata() {
    local bvid="$1"
    $CURL -s "https://api.bilibili.com/x/web-interface/view?bvid=$bvid" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null
}

# If no title provided, fetch from API
if [[ -z "$TITLE" ]]; then
    META=$(get_metadata "$BVID")
    TITLE=$(echo "$META" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['data']['title'] if d.get('code')==0 else '$BVID')" 2>/dev/null || echo "$BVID")
fi
SAFE_TITLE=$(sanitize_title "$TITLE")

# --- Detect available download tools ---
has_yt_dlp() { command -v yt-dlp &>/dev/null; }
has_you_get() { command -v you-get &>/dev/null; }
has_ffmpeg() { command -v ffmpeg &>/dev/null; }

# --- Check if video is charged/premium-exclusive (充电专属) ---
# Such videos gate the full stream behind payment; only a ~15-min preview is
# served (with OR without cookies — verified via direct WBI-signed playurl calls).
# We detect and SKIP them. See SKILL.md "Charged/Premium-exclusive videos".
# Returns 0 (true) if charged, 1 (false) otherwise.
is_charged_video() {
    get_metadata "$BVID" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    sys.exit(0 if (d.get('code') == 0 and d['data'].get('is_upower_exclusive')) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# --- Download with yt-dlp (COOKIELESS) ---
# Per skill policy we download ANONYMOUSLY — NO --cookies-from-browser. This also
# avoids the macOS Keychain hang. yt-dlp usually 412s on Bilibili's WBI playurl
# regardless of cookies; you-get is the reliable path. Kept as a best-effort fallback.
# Returns 0 on success, 1 on failure.
yt_dlp_with_retry() {
    local extra_args=("$@")
    echo "[yt-dlp] Trying (cookieless)..."
    if PYTHONIOENCODING=utf-8 yt-dlp --proxy "" "${extra_args[@]}" "$URL" 2>&1; then
        return 0
    fi
    return 1
}

# --- Download with you-get ---
# Wrapped in a hang watchdog: Bilibili's CDN throttles anonymous connections and
# the transfer can die mid-stream, at which point you-get waits forever (it has
# no resume flag in 0.4.1743 — "-c" means cookies). Kill it after $1 seconds.
# Usage: you_get_download [timeout_secs] [format]; default timeout 2700 (45min).
# Returns 0 on success, 1 on failure, 124 on timeout
you_get_download() {
    local timeout_secs="${1:-2700}"
    local format="${2:-best}"
    if ! has_you_get; then
        echo "[you-get] Not installed, skipping"
        return 1
    fi

    echo "[you-get] Downloading with format=$format (watchdog: ${timeout_secs}s)..."
    run_with_timeout "$timeout_secs" \
        env PYTHONIOENCODING=utf-8 you-get --format="$format" \
        -o "$OUTDIR" "$URL" 2>&1
}

# --- Run a command with a hard timeout (macOS ships no GNU `timeout`) ---
# Usage: run_with_timeout <seconds> <cmd...>. Returns 124 if killed.
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    # 143 = SIGTERM from our watcher → normalize to GNU timeout's 124
    [[ $rc -eq 143 ]] && rc=124
    return $rc
}

# --- Audio-only direct path (primary audio strategy since 2026-10) ---
# Delegates to bili-audio-only.py: extracts the audio-stream URL via `you-get -u`
# and downloads just the audio .m4s with curl (stall-proof, full speed, ~60% less
# data than full-format download). See that script's docstring for the field report.
# Returns 0 on success; nonzero → caller falls back to full download chain.
audio_only_direct() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local py="$script_dir/bili-audio-only.py"
    if [[ ! -f "$py" ]] || ! command -v python3 &>/dev/null; then
        echo "[audio-direct] helper or python3 unavailable, falling back"
        return 2
    fi
    echo "[audio-direct] Trying audio-stream-only download (fast path)..."
    python3 "$py" "$BVID" "$OUTDIR" "$TITLE"
}

# --- Convert FLV to MP4 if needed ---
convert_flv_to_mp4() {
    local flv_file="$OUTDIR/${SAFE_TITLE}.flv"
    local mp4_file="$OUTDIR/${SAFE_TITLE}.mp4"

    if [[ -f "$flv_file" ]]; then
        echo "[convert] FLV -> MP4: $SAFE_TITLE"
        if has_ffmpeg; then
            ffmpeg -i "$flv_file" -c copy "$mp4_file" -y 2>&1 | tail -3
            rm "$flv_file"
            echo "[convert] Done"
        else
            echo "[convert] ffmpeg not available, keeping FLV file"
            mv "$flv_file" "$mp4_file"
        fi
    fi
}

# --- Extract audio from video file ---
extract_audio_from_file() {
    local video_file="$1"
    local mp3_file="$OUTDIR/${SAFE_TITLE}.mp3"

    if [[ -f "$mp3_file" ]]; then
        echo "[SKIP] ${SAFE_TITLE}.mp3 already exists"
        return 0
    fi

    echo "[audio] Extracting MP3 from: $(basename "$video_file")"
    if has_ffmpeg; then
        # Try to embed thumbnail
        local thumb_file="$OUTDIR/${SAFE_TITLE}.jpg"
        # Get thumbnail URL from metadata
        local thumb_url
        thumb_url=$(get_metadata "$BVID" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
if d.get('code') == 0:
    pic = d['data'].get('pic', '')
    # Convert http to https
    if pic.startswith('http://'):
        pic = 'https://' + pic[7:]
    print(pic)
" 2>/dev/null || echo "")

        if [[ -n "$thumb_url" ]]; then
            $CURL -s -o "$thumb_file" "$thumb_url" 2>/dev/null
        fi

        if [[ -f "$thumb_file" ]]; then
            # Embed cover art. NO -vn: -vn disables ALL video output and would drop the
            # mapped thumbnail. Mark the image as an attached_pic (APIC frame) instead.
            ffmpeg -i "$video_file" -i "$thumb_file" \
                -map 0:a:0 -map 1:0 -c:a libmp3lame -q:a 0 \
                -c:v copy -disposition:v:0 attached_pic \
                -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
                -id3v2_version 3 "$mp3_file" -y 2>&1 | tail -3
            rm -f "$thumb_file"
        else
            ffmpeg -i "$video_file" -vn -acodec libmp3lame -q:a 0 \
                "$mp3_file" -y 2>&1 | tail -3
        fi
        echo "[audio] Done: ${SAFE_TITLE}.mp3"
    else
        echo "[audio] ffmpeg not available, cannot extract audio"
        return 1
    fi
}

# --- Get you-get best available format ---
# IMPORTANT: Bilibili now serves DASH formats named "dash-flv{360,480,720,1080}-{AVC,HEVC,AV1}".
# The legacy names (flv480, flv720, mp4, ...) no longer exist for most videos. Passing a stale
# name makes you-get fail with "oops, something went wrong". We must return the EXACT format
# string including the codec suffix. See SKILL.md "Critical: you-get DASH format names".
you_get_best_format() {
    local info
    info=$(you-get -i "$URL" 2>&1)
    # Prefer higher resolution, then AVC (most compatible) > HEVC > AV1
    for res in 1080 720 480 360; do
        for codec in AVC HEVC AV1; do
            local fmt="dash-flv${res}-${codec}"
            if echo "$info" | grep -q "format:.*${fmt}"; then
                echo "$fmt"
                return
            fi
        done
    done
    # Legacy non-DASH formats (a few older videos still expose these)
    for fmt in flv1080 flv720 mp4 mp4hd flv480 flv360; do
        if echo "$info" | grep -q "format:.*$fmt"; then
            echo "$fmt"
            return
        fi
    done
    echo "worst"
}

# --- Mode handlers ---

do_video() {
    local mp4_file="$OUTDIR/${SAFE_TITLE}.mp4"
    local flv_file="$OUTDIR/${SAFE_TITLE}.flv"

    # Skip if already downloaded
    [[ -f "$mp4_file" ]] && echo "[SKIP] ${SAFE_TITLE}.mp4 already exists" && return 0

    echo "[DL] Video: $TITLE ($BVID)"

    # Strategy 1: yt-dlp with cookies
    if has_yt_dlp; then
        if yt_dlp_with_retry \
            -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" \
            --merge-output-format mp4 \
            -o "$mp4_file"; then
            return 0
        fi
    fi

    # Strategy 2: you-get (with hang watchdog)
    local fmt
    fmt=$(you_get_best_format)
    if you_get_download 2700 "$fmt"; then
        convert_flv_to_mp4
        return 0
    fi

    echo "[ERROR] All download methods failed for $BVID"
    return 1
}

do_audio() {
    local mp3_file="$OUTDIR/${SAFE_TITLE}.mp3"
    [[ -f "$mp3_file" ]] && echo "[SKIP] ${SAFE_TITLE}.mp3 already exists" && return 0

    echo "[DL] Audio: $TITLE ($BVID)"

    # Strategy 1 (primary): audio-only direct path — download just the audio
    # stream. Fast, stall-proof, and the audio is identical to what a full
    # 480P download would carry. Exits 2 (no URL / charged / multi-P) or 3 (dl
    # failed) → fall through to the full-download chain below.
    audio_only_direct && return 0

    # Strategy 2: you-get full format + ffmpeg extract
    local video_file
    # Check if video already exists
    for ext in mp4 flv; do
        if [[ -f "$OUTDIR/${SAFE_TITLE}.$ext" ]]; then
            video_file="$OUTDIR/${SAFE_TITLE}.$ext"
            break
        fi
    done

    # If no video file, download it first
    if [[ -z "${video_file:-}" ]]; then
        local fmt
        fmt=$(you_get_best_format)
        if you_get_download 2700 "$fmt"; then
            # Find the downloaded file. you-get names it by the REAL Bilibili title,
            # which may differ from SAFE_TITLE (e.g. halfwidth "," vs fullwidth "，",
            # or "?" vs "？"). Try SAFE_TITLE first, then fall back to the newest
            # mp4/flv in OUTDIR (the file you-get just produced).
            for ext in mp4 flv; do
                if [[ -f "$OUTDIR/${SAFE_TITLE}.$ext" ]]; then
                    video_file="$OUTDIR/${SAFE_TITLE}.$ext"
                    break
                fi
            done
            if [[ -z "${video_file:-}" ]]; then
                video_file=$(ls -t "$OUTDIR"/*.mp4 "$OUTDIR"/*.flv 2>/dev/null | head -1)
            fi
        fi
    fi

    if [[ -n "${video_file:-}" ]] && extract_audio_from_file "$video_file"; then
        return 0
    fi

    # Strategy 3: yt-dlp (usually 412s on Bilibili's playurl; last resort)
    if has_yt_dlp; then
        yt_dlp_with_retry \
            -x --audio-format mp3 --audio-quality 0 --embed-thumbnail \
            -o "$OUTDIR/${SAFE_TITLE}.%(ext)s" && return 0
    fi

    echo "[ERROR] All audio download methods failed for $BVID"
    return 1
}

do_video_audio() {
    local mp4_file="$OUTDIR/${SAFE_TITLE}.mp4"
    local mp3_file="$OUTDIR/${SAFE_TITLE}.mp3"

    # Download video first
    do_video

    # Extract audio from the video file
    if [[ -f "$mp4_file" ]]; then
        extract_audio_from_file "$mp4_file"
    fi
}

do_thumbnail() {
    local outfile="$OUTDIR/${SAFE_TITLE}"

    # Try API first (no yt-dlp needed, more reliable)
    local thumb_url
    thumb_url=$(get_metadata "$BVID" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
if d.get('code') == 0:
    pic = d['data'].get('pic', '')
    if pic.startswith('http://'):
        pic = 'https://' + pic[7:]
    print(pic)
" 2>/dev/null || echo "")

    if [[ -n "$thumb_url" ]]; then
        echo "[DL] Thumbnail: $TITLE ($BVID)"
        $CURL -s -o "${outfile}.jpg" "$thumb_url" 2>/dev/null
        if [[ -f "${outfile}.jpg" ]]; then
            echo "[DL] Thumbnail saved: ${SAFE_TITLE}.jpg"
            return 0
        fi
    fi

    # Fallback to yt-dlp
    if has_yt_dlp; then
        echo "[DL] Thumbnail (yt-dlp fallback): $TITLE ($BVID)"
        yt_dlp_with_retry --write-thumbnail --skip-download -o "$outfile"
        return $?
    fi

    echo "[ERROR] Could not download thumbnail for $BVID"
    return 1
}

do_metadata() {
    echo "[META] Fetching metadata for $BVID"
    local meta
    meta=$(get_metadata "$BVID")
    echo "$meta" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
if d.get('code') == 0:
    v = d['data']
    print(f\"title: {v['title']}\")
    print(f\"uploader: {v['owner']['name']}\")
    print(f\"duration: {v['duration']}\")
    print(f\"pages: {len(v.get('pages', []))}\")
    for i, p in enumerate(v.get('pages', [])):
        print(f\"  P{i+1}: {p['part']} ({p['duration']}s)\")
    print(f\"description: {v.get('desc', '')[:300]}\")
    # Flag charged videos
    if v.get('is_upower_exclusive'):
        print(f\"WARNING: This is a charged/premium-exclusive video (is_upower_exclusive)\")
    rights = v.get('rights', {})
    if rights.get('pay') or rights.get('ugc_pay'):
        print(f\"WARNING: This video requires payment (pay={rights.get('pay')}, ugc_pay={rights.get('ugc_pay')})\")
    print(f\"resolution: {v.get('dimension', {}).get('width')}x{v.get('dimension', {}).get('height')}\")
else:
    print(f'error: {d}')
" 2>/dev/null
}

# --- Skip charged/premium-exclusive videos for download modes ---
# metadata/thumbnail are still allowed (public even for charged videos).
if [[ "$MODE" == "audio" || "$MODE" == "video" || "$MODE" == "video+audio" ]]; then
    if is_charged_video; then
        echo "[CHARGED] SKIP: $TITLE ($BVID) — is_upower_exclusive (paid video; full stream requires payment). No file written."
        exit 0
    fi
fi

# --- Main dispatch ---
case "$MODE" in
    audio)         do_audio ;;
    video)         do_video ;;
    video+audio)   do_video_audio ;;
    thumbnail)     do_thumbnail ;;
    metadata)      do_metadata ;;
    *)             echo "Unknown mode: $MODE. Supported: audio, video, video+audio, thumbnail, metadata" >&2; exit 1 ;;
esac
