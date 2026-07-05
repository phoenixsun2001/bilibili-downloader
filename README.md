# bilibili-downloader

A [Claude Code](https://claude.com/claude-code) skill for downloading videos, audio (MP3), and thumbnails from Bilibili (B站).

See [`SKILL.md`](SKILL.md) for the full workflow and [`scripts/bili-dl.sh`](scripts/bili-dl.sh) for the download helper.

## Highlights
- **Anonymous (cookieless) downloads** via you-get — no browser cookies or Keychain access.
- **Auto-skip charged / premium-exclusive videos** (`is_upower_exclusive`).
- DASH stream-format detection (`dash-flv480-AVC`, etc.).
- Multi-strategy fallback: you-get → yt-dlp (cookieless).
- Automatic `catalog.csv` generation.

## Requirements
```bash
which yt-dlp   || brew install yt-dlp
which ffmpeg   || brew install ffmpeg
which you-get  || pip install you-get
```
