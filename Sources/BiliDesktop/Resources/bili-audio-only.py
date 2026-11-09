#!/usr/bin/env python3
"""bili-audio-only.py — Download ONLY the audio stream of a Bilibili video and convert to MP3.

Why this exists (2026-10 field report): the "download full video then extract audio" path
is slow and unreliable — Bilibili's CDN throttles anonymous connections (~50kB/s after the
first ~100MB) and the connection eventually dies, at which point you-get hangs FOREVER
(you-get 0.4.1743 has no resume flag; `-c` means cookies, not continue). Meanwhile a
freshly signed stream URL downloaded via curl runs at full speed. Since the audio stream
is identical across all video qualities, for audio/MP3 purposes we skip the video stream
entirely (~60% less data) and pull the audio .m4s directly.

Method:
  1. `you-get -u` prints the real DASH stream URLs without downloading (playurl API
     direct calls 412 even with a fresh WBI signature — you-get's extraction works).
  2. Pick the best audio stream by ID: 30251 (flac) > 30250 (dolby) > 30280 (192k AAC)
     > 30232 (132k) > 30216 (64k). Anonymous sessions get 30280 at best.
  3. curl with `--speed-limit` (auto-abort dead connections) + `-C -` (resume on retry).
  4. ffmpeg → MP3 VBR q0 with embedded cover art.

Usage: python3 bili-audio-only.py <bvid> <output_dir> [title]
Exit codes: 0 = ok / already exists, 2 = no audio URL (fallback to full download),
            3 = download or conversion failed, 4 = multi-part video (fallback needed)
"""

import os
import re
import subprocess
import sys
import time
import urllib.request
import json

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
AUDIO_IDS = ["30251", "30250", "30280", "30232", "30216"]  # best first


def sh(cmd, timeout=180):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def api_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return json.loads(urllib.request.urlopen(req, timeout=15).read().decode())


def get_audio_url(bvid, tries=4):
    """Extract the best audio-stream URL via `you-get -u`. you-get can itself be
    rate-limited/hang, so subprocess timeout + retries."""
    for i in range(tries):
        try:
            r = sh(["you-get", "-u", "--format=dash-flv480-AVC",
                    f"https://www.bilibili.com/video/{bvid}/"], timeout=120)
            urls = re.findall(r"https://\S+\.m4s\S*", r.stdout)
            for aid in AUDIO_IDS:  # priority order
                for u in urls:
                    if f"-{aid}.m4s" in u:
                        return u, aid
            print(f"  [you-get returned no audio URL, attempt {i + 1}]", flush=True)
        except subprocess.TimeoutExpired:
            print(f"  [you-get hung, attempt {i + 1}]", flush=True)
        time.sleep(5)
    return None, None


def curl_dl(url, path, tries=8):
    """Download with stall detection. --speed-limit aborts if <20KB/s for 45s;
    -C - resumes from the partial file on the next attempt."""
    for i in range(tries):
        r = subprocess.run(
            ["/usr/bin/curl", "-sS", "-C", "-", "-o", path,
             "-H", f"User-Agent: {UA}",
             "-H", "Referer: https://www.bilibili.com/",
             "--speed-limit", "20480", "--speed-time", "45",
             "--max-time", "600", url])
        if r.returncode == 0:
            return True
        print(f"  [curl exit={r.returncode}, retry {i + 1}] {time.strftime('%H:%M:%S')}",
              flush=True)
        if r.returncode == 33 and os.path.exists(path):  # range unsupported → fresh
            os.remove(path)
        time.sleep(3)
    return False


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    bvid, outdir = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    os.makedirs(outdir, exist_ok=True)

    view = api_json(f"https://api.bilibili.com/x/web-interface/view?bvid={bvid}")
    if view.get("code") != 0:
        print(f"  [view API error] {view.get('code')} {view.get('message')}")
        sys.exit(2)
    data = view["data"]
    if data.get("is_upower_exclusive"):
        print("  [CHARGED] is_upower_exclusive — audio gated behind payment, skipping")
        sys.exit(2)
    if len(data.get("pages", [])) > 1:
        print(f"  [MULTI-P] {len(data['pages'])} pages — audio-only path handles P1 only")
        sys.exit(4)
    if not title:
        title = data["title"]
    pic = data.get("pic", "").replace("http://", "https://", 1)

    safe = re.sub(r'[\\/:*?"<>|\n\r\t]', "_", title)
    mp3 = os.path.join(outdir, f"{safe}.mp3")
    if os.path.exists(mp3) and os.path.getsize(mp3) > 1_000_000:
        print(f"[SKIP] {mp3} already exists")
        sys.exit(0)

    print(f"[audio-direct] {title} ({bvid})", flush=True)
    url, aid = get_audio_url(bvid)
    if not url:
        sys.exit(2)
    print(f"  [audio stream] id={aid} (best available anonymously)", flush=True)

    # Temp file keyed by bvid so re-invocations resume instead of restarting
    tmp = f"/tmp/bili_audio_{bvid}.m4s"
    if not curl_dl(url, tmp):
        sys.exit(3)
    size = os.path.getsize(tmp) / 1e6
    print(f"  [downloaded] {size:.1f}MB", flush=True)

    # Cover art (embedded into the MP3)
    cover = "/tmp/bili_cover.jpg"
    have_cover = False
    try:
        req = urllib.request.Request(pic, headers={"User-Agent": UA,
                                                   "Referer": "https://www.bilibili.com/"})
        with urllib.request.urlopen(req, timeout=20) as r, open(cover, "wb") as f:
            f.write(r.read())
        have_cover = os.path.getsize(cover) > 0
    except Exception as e:
        print(f"  [cover fetch failed — continuing without] {e}", flush=True)

    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", tmp]
    if have_cover:
        cmd += ["-i", cover, "-map", "0:a", "-map", "1:v",
                "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
    cmd += ["-c:a", "libmp3lame", "-q:a", "0",
            "-metadata", f"title={title}",
            "-metadata", "artist=" + data.get("owner", {}).get("name", ""),
            mp3]
    r = sh(cmd, timeout=1200)
    os.remove(tmp)
    if have_cover:
        os.remove(cover)
    if r.returncode != 0 or not os.path.exists(mp3):
        print(f"  [ffmpeg failed] {r.stderr[:300]}")
        sys.exit(3)
    print(f"[MP3] {mp3} ({os.path.getsize(mp3) / 1e6:.0f}MB)", flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
