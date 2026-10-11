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

### User space videos (WBI-signed — reliable when signed correctly)

```
GET https://api.bilibili.com/x/space/wbi/arc/search?mid={UID}&ps=30&pn=1&order=pubdate
```

This endpoint requires WBI signature (verified working 2026-10 — returns the UP主's videos
newest-first with `created` timestamps; ideal for "latest N videos after date X" requests).
Rate-limits rapid successive calls (HTTP 412) — add `sleep 3` between pages and retry.

**WBI signing recipe** (get the UP主's `mid` from any of their videos via the view API,
`data.owner.mid`):

```python
import hashlib, json, time, urllib.parse, urllib.request

MIXIN = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,
         33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,
         61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,
         36,20,34,44,52]

def get(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 ...", "Referer": "https://www.bilibili.com/"})
    return json.loads(urllib.request.urlopen(req, timeout=15).read().decode())

nav = get("https://api.bilibili.com/x/web-interface/nav")["data"]["wbi_img"]
raw = (nav["img_url"].rsplit("/", 1)[1].split(".")[0] +
       nav["sub_url"].rsplit("/", 1)[1].split(".")[0])
mixin_key = "".join(raw[i] for i in MIXIN)[:32]

params = {"mid": "17004561", "ps": "30", "pn": "1", "order": "pubdate",
          "platform": "web", "web_location": "1550101", "wts": str(int(time.time()))}
qs = urllib.parse.urlencode(sorted(params.items()))
params["w_rid"] = hashlib.md5((qs + mixin_key).encode()).hexdigest()
data = get("https://api.bilibili.com/x/space/wbi/arc/search?" +
           urllib.parse.urlencode(params))
# data["data"]["list"]["vlist"] → [{bvid, title, created (unix), length ("43:12"), ...}]
```

**IMPORTANT — playurl is NOT reachable this way:** `x/player/wbi/playurl` returns 412
*even with* a correct fresh WBI signature (extra protection beyond signing, verified
2026-10). Don't hand-roll playurl calls; extract direct stream URLs from `you-get -u`
output instead (see SKILL.md "audio downloads — audio-only direct path").

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
