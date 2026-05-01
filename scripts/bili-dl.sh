#!/bin/bash
# bili-dl.sh — Bilibili download helper with multi-tool fallback
# Usage: bili-dl.sh <mode> <bvid> <output_dir> [title]
# Modes: audio, video, video+audio, thumbnail, metadata
#
# Download strategy (tried in order):
#   1. yt-dlp with browser cookies (best quality)
#   2. you-get (up to 720P, no login needed)
#   3. yt-dlp without cookies (last resort)

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

# --- Detect browsers for cookies ---
detect_browsers() {
    local browsers=()
    [[ "$(uname)" == "Darwin" ]] && browsers+=("safari")
    [[ -d "/Applications/Google Chrome.app" ]] && browsers+=("chrome")
    [[ -d "/Applications/Microsoft Edge.app" ]] && browsers+=("edge")
    [[ -d "/Applications/Firefox.app" ]] || command -v firefox &>/dev/null && browsers+=("firefox")
    [[ -d "/Applications/Brave Browser.app" ]] && browsers+=("brave")
    echo "${browsers[@]}"
}

# --- Download with yt-dlp, trying each browser ---
# Returns 0 on success, 1 on failure
yt_dlp_with_retry() {
    local extra_args=("$@")
    local browsers
    browsers=$(detect_browsers)

    # Try with each browser's cookies
    for browser in $browsers; do
        echo "[yt-dlp] Trying with $browser cookies..."
        if PYTHONIOENCODING=utf-8 yt-dlp --cookies-from-browser "$browser" \
            --proxy "" "${extra_args[@]}" "$URL" 2>&1; then
            return 0
        fi
        echo "[yt-dlp] Failed with $browser, trying next..."
    done

    # Try without cookies as last resort
    echo "[yt-dlp] Trying without cookies..."
    if PYTHONIOENCODING=utf-8 yt-dlp --proxy "" "${extra_args[@]}" "$URL" 2>&1; then
        return 0
    fi

    return 1
}

# --- Download with you-get ---
# Returns 0 on success, 1 on failure
you_get_download() {
    local format="${1:-best}"
    if ! has_you_get; then
        echo "[you-get] Not installed, skipping"
        return 1
    fi

    echo "[you-get] Downloading with format=$format..."
    if PYTHONIOENCODING=utf-8 you-get --format="$format" \
        -o "$OUTDIR" "$URL" 2>&1; then
        return 0
    fi
    return 1
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
            ffmpeg -i "$video_file" -vn -acodec libmp3lame -q:a 0 \
                -i "$thumb_file" -c copy -map 0:a -map 1:0 \
                -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
                "$mp3_file" -y 2>&1 | tail -3
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
you_get_best_format() {
    local info
    info=$(you-get -i "$URL" 2>&1)
    # Prefer higher quality formats
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

    # Strategy 2: you-get
    local fmt
    fmt=$(you_get_best_format)
    if you_get_download "$fmt"; then
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

    # Strategy 1: yt-dlp audio extraction
    if has_yt_dlp; then
        if yt_dlp_with_retry \
            -x --audio-format mp3 --audio-quality 0 --embed-thumbnail \
            -o "$OUTDIR/${SAFE_TITLE}.%(ext)s"; then
            return 0
        fi
    fi

    # Strategy 2: you-get + ffmpeg extract
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
        if you_get_download "$fmt"; then
            # Find the downloaded file
            for ext in mp4 flv; do
                if [[ -f "$OUTDIR/${SAFE_TITLE}.$ext" ]]; then
                    video_file="$OUTDIR/${SAFE_TITLE}.$ext"
                    break
                fi
            done
        fi
    fi

    if [[ -n "${video_file:-}" ]]; then
        extract_audio_from_file "$video_file"
        return $?
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

# --- Main dispatch ---
case "$MODE" in
    audio)         do_audio ;;
    video)         do_video ;;
    video+audio)   do_video_audio ;;
    thumbnail)     do_thumbnail ;;
    metadata)      do_metadata ;;
    *)             echo "Unknown mode: $MODE. Supported: audio, video, video+audio, thumbnail, metadata" >&2; exit 1 ;;
esac
