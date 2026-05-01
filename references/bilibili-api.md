# Bilibili API Reference

## Important: Proxy Interference

If the system has a curl proxy (e.g. `rtk` - Rust Token Killer), bare `curl` calls may be intercepted and return non-JSON responses. **Always use `/usr/bin/curl` directly** for Bilibili API calls to bypass proxies:

```bash
# WRONG (may be intercepted by rtk)
curl -s "https://api.bilibili.com/x/web-interface/view?bvid=BVxxx"

# CORRECT (bypasses proxy)
/usr/bin/curl -s "https://api.bilibili.com/x/web-interface/view?bvid=BVxxx"
```

## Video Discovery APIs

### Related videos (most reliable, no auth needed)

```
GET https://api.bilibili.com/x/web-interface/archive/related?bvid={BV_ID}
Headers:
  User-Agent: Mozilla/5.0 ...
  Referer: https://www.bilibili.com/
```

Returns up to 30 related/recommended videos. Filter by `owner.name` to find more videos from the same UP主. This is the best way to discover all videos in a series.

**Example response structure:**
```json
{
  "code": 0,
  "data": [
    {
      "bvid": "BV1xxx",
      "title": "视频标题",
      "owner": { "name": "UP主名", "mid": 12345 },
      "duration": 1523,
      "pic": "https://..."
    }
  ]
}
```

### Video metadata (no auth needed)

```
GET https://api.bilibili.com/x/web-interface/view?bvid={BV_ID}
Headers:
  User-Agent: Mozilla/5.0 ...
  Referer: https://www.bilibili.com/
```

Returns full video metadata including title, description, duration, owner info, pages (for multi-part videos).

**Important fields for charged/premium videos:**
- `is_upower_exclusive`: `true` means the video is premium-exclusive (paid content)
- `rights.pay`: `1` means payment required
- `rights.ugc_pay`: `1` means UGC payment required
- These videos can still be downloaded at lower quality (e.g. 720P) without payment

### Video search (often requires WBI signature or returns captcha)

```
GET https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword={KEYWORD}&mid={UP主UID}&page=1
```

This endpoint often requires WBI signature verification. **Prefer web search over this API** for finding videos by keyword. The API frequently returns captcha pages for automated access.

### User space videos (requires WBI signature)

```
GET https://api.bilibili.com/x/space/wbi/arc/search?mid={UID}&keyword={KEYWORD}&ps=30&pn=1
```

This endpoint requires WBI signature (signed query parameters). The signing keys rotate periodically. For simplicity, prefer web search + related-videos API traversal.

## User info

```
GET https://api.bilibili.com/x/space/acc/info?mid={UID}
```

Returns user profile including name, sign, face (avatar URL).

## Strategies for finding all videos by an UP主

### Strategy 1: Web search (recommended)
1. Search `"<UP主名>" "<关键词>" site:bilibili.com/video` using web search
2. Extract BV numbers from search results
3. Verify each belongs to the target UP主 via metadata API
4. **This is the most reliable method** because Bilibili's own search API often requires WBI or returns captchas

### Strategy 2: Related-videos traversal
1. Find one known video from the UP主
2. Call related-videos API
3. Filter results by `owner.name == target_UP主`
4. For each found video, call related-videos API again
5. Deduplicate by BV number
6. Stop when no new videos are found

### Strategy 3: yt-dlp (limited)
1. `yt-dlp --flat-playlist "https://space.bilibili.com/{UID}/video"`
2. May fail with 412 (rate limiting) or encoding errors

## Common BV number patterns

BV numbers start with "BV1" and are 12 characters long. Examples:
- BV1dh4y1L7eS
- BV1Mj411E7c2

## Rate limiting and 412 errors

- Bilibili returns HTTP 412 for two distinct reasons:
  1. **WBI signature rejection** — yt-dlp requests to the playurl API are routinely rejected, even with browser cookies. Bilibili frequently updates their WBI algorithm. When this happens, fall back to you-get which uses a different API endpoint.
  2. **Actual rate limiting** — after ~20 rapid requests, Bilibili may throttle. Fix: add `sleep 2` between requests or use `--sleep-requests 2` in yt-dlp.
- The Bilibili web-interface API (`/x/web-interface/view`, `/x/web-interface/archive/related`) does NOT require cookies and works reliably without them. Use these for metadata and video discovery.
- Captcha pages may be returned for excessive automated access
- If yt-dlp consistently fails with 412 even with cookies, the WBI algorithm may be outdated. Fall back to you-get instead of retrying.
