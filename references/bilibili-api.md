# Bilibili API Reference

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

### Video search (may require auth/WBI signature)

```
GET https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword={KEYWORD}&mid={UP主UID}&page=1
```

This endpoint often requires WBI signature verification. Prefer the related-videos API for discovery.

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

### Strategy 1: Related-videos traversal (recommended)
1. Find one known video from the UP主
2. Call related-videos API
3. Filter results by `owner.name == target_UP主`
4. For each found video, call related-videos API again
5. Deduplicate by BV number
6. Stop when no new videos are found

### Strategy 2: Web search
1. Search `"<UP主名>" "<关键词>" bilibili.com/video`
2. Extract BV numbers from search results
3. Verify each belongs to the target UP主 via metadata API

### Strategy 3: yt-dlp (limited)
1. `yt-dlp --flat-playlist "https://space.bilibili.com/{UID}/video"`
2. May fail with 412 (rate limiting) or encoding errors

## Common BV number patterns

BV numbers start with "BV1" and are 12 characters long. Examples:
- BV1dh4y1L7eS
- BV1Mj411E7c2

## Rate limiting

- Bilibili may return HTTP 412 when rate-limited
- Add delays between requests: `--sleep-requests 2` in yt-dlp
- For API calls, add 1-2 second delays between requests
- Captcha pages may be returned for excessive automated access
