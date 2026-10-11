# bilibili-downloader

一个 [Claude Code](https://claude.com/claude-code) skill，用于从 Bilibili（B站）下载视频、音频（MP3）、封面，支持批量下载并自动生成目录。

完整工作流见 [`SKILL.md`](SKILL.md)，下载脚本见 [`scripts/bili-dl.sh`](scripts/bili-dl.sh)。

## 功能特性

- **音频直连快速路径（2026-10 新增）** — `you-get -u` 提取音频流直链，curl 直接下载 `.m4s`：跳过视频流省 60% 流量，新签名连接不限速，带卡死自动断开 + 断点续传
- **匿名（无 cookie）下载** — 全程不使用浏览器 cookie，无钥匙串弹窗；公共视频匿名即可下载
- **自动跳过充电专属视频**（`is_upower_exclusive`）— 检测到付费内容干净跳过，不做 15 分钟预览的无用功
- **WBI 签名空间 API** — 获取 UP 主最新视频列表（按发布时间），支持"某日期之后的 N 个视频"类需求
- **DASH 流格式识别**（`dash-flv480-AVC` 等），you-get 下载带 45 分钟防挂起看门狗
- **多策略兜底** — 音频：直连 → you-get 整格式 → yt-dlp；视频：yt-dlp → you-get
- **自动目录** — 生成 `catalog.csv`（BV号、标题、UP主、时长、下载类型、跳过原因）

## 环境要求

```bash
# 必装
brew install yt-dlp ffmpeg
# 推荐（yt-dlp 在 B 站经常 412，you-get 是可靠路径）
pip install you-get
```

## 使用方法

此 skill 通过 Claude Code 调用，在会话中说"下载 B站视频 BVxxx"、"下载某UP主7月之后的3个视频并转MP3"等即可触发。

### 通过脚本手动使用

```bash
# 下载音频为 MP3（内嵌封面，自动走音频直连快速路径）
bash scripts/bili-dl.sh audio "BV1dh4y1L7eS" "./output"

# 仅下载音频流（独立工具，效果同上）
python3 scripts/bili-audio-only.py "BV1dh4y1L7eS" "./output"

# 下载视频 / 视频+音频 / 封面 / 查看元数据
bash scripts/bili-dl.sh video       "BV1dh4y1L7eS" "./output"
bash scripts/bili-dl.sh video+audio "BV1dh4y1L7eS" "./output"
bash scripts/bili-dl.sh thumbnail   "BV1dh4y1L7eS" "./output"
bash scripts/bili-dl.sh metadata    "BV1dh4y1L7eS" "./output"
```

## 文件结构

```
bilibili-downloader/
├── SKILL.md                       # Skill 定义（核心文件）
├── README.md
├── references/
│   └── bilibili-api.md            # B站 API 参考（含可运行的 WBI 签名配方）
└── scripts/
    ├── bili-dl.sh                 # 下载脚本（多策略兜底 + 防挂起看门狗）
    └── bili-audio-only.py         # 音频直连下载器（you-get -u → 音频流 → MP3）
```

## 实战经验（写进代码的教训）

- **yt-dlp 对 B 站 playurl API 几乎必 412**（WBI 签名问题），即使最新版也是如此——别浪费时间重试或升级
- **playurl API 直调即使 WBI 签名正确也 412**——要拿流直链就用 `you-get -u` 的输出
- **you-get 整格式下载会被 CDN 限速后挂死**（~100MB 后降到 50kB/s，连接断开后无续传参数、永久等待）——音频需求请走直连路径
- **音频流与视频清晰度无关**（匿名最高 192kbps AAC）——要 MP3 就别下视频流

## 许可

MIT
