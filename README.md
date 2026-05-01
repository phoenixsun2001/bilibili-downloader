# Bilibili Downloader

一个 Claude Code 的 skill，用于从 Bilibili（B站）下载视频、音频、封面，支持批量下载并自动生成目录。

## 功能

- **音频下载** — 提取最高质量的 MP3 音频，内嵌封面
- **视频下载** — 下载最佳画质的 MP4 视频
- **封面下载** — 单独保存视频封面图片
- **批量下载** — 支持按 BV 号列表、UP主+关键词、合集链接批量下载
- **自动目录** — 下载完成后生成 `catalog.csv`，记录 BV 号、标题、UP主、时长等元数据

## 环境要求

```bash
brew install yt-dlp ffmpeg
```

## 使用方法

此 skill 通过 Claude Code 调用。在 Claude Code 会话中，触发词包括：

- "下载 B站视频 BVxxx"
- "下载这个UP主的所有XX视频"
- "把 BVxxx 转成 MP3"

Claude Code 会自动加载此 skill 并引导你完成下载配置。

### 手动下载示例

```bash
# 下载单个视频的音频
PYTHONIOENCODING=utf-8 yt-dlp \
  -x --audio-format mp3 --audio-quality 0 --embed-thumbnail \
  -o "%(title)s.%(ext)s" \
  "https://www.bilibili.com/video/BV1dh4y1L7eS/"
```

## 文件结构

```
bilibili-downloader/
├── SKILL.md                  # Skill 定义（核心文件）
├── references/
│   └── bilibili-api.md       # B站 API 参考文档
└── scripts/                  # 动态脚本目录（skill 运行时自动生成）
```

## 注意事项

- **限流**：B站对频繁请求会返回 HTTP 412。大批量下载时会自动添加请求间隔
- **会员内容**：部分视频需要登录。如有大会员账号，可使用 `--cookies-from-browser` 参数
- **分P视频**：自动检测并下载每个分P
- **文件名冲突**：自动追加 BV 号以避免覆盖

## 许可

MIT
