# EasySave parsing specification

## Unified output

Fixture pairs used to validate this contract live under spec/fixtures/.

Parsers produce `{ platform, id, url, author: { name?, id? }, title?, caption?, publishedAt?, items: [{ type: image|video|live, url, videoUrl?, posterUrl?, width?, height?, duration? }] }`.
`platform` is `xhs`, `instagram`, or `x`. `url` is the canonical post URL.
`items` preserves source order. `live` represents a still image paired with its
motion asset via `videoUrl`. In v1, `live` is only an image+video pair; no
motion-photo synthesis is performed.
`duration` is the video length in seconds, present only on `video` items and
only when the source provides it: XHS reads `video.capa.duration`, Instagram
reads `video_duration`, X reads `video_info.duration_millis / 1000`. When absent, the UI shows a bare play badge.
`posterUrl` is the still-image cover for a `video` item, taken from XHS
`imageList[0]` or X `media_url_https?name=orig` (IG video items already carry the preview image in `url`, so
it stays null there). The UI renders `posterUrl` for video thumbnails because
the item `url` itself may be an mp4 that image widgets cannot display.

v1 scope exclusions: comment-section images, Stories, and OG fallback on post
pages. When structured parsing fails, return an explicit parse error instead of
a partial or empty success.

**Error model.** Parse failures use { code, message } and never return a successful empty result. The v1 codes are LOGIN_REQUIRED for a login wall or authenticated-only page, PRIVATE_OR_UNAVAILABLE for private, deleted, or unavailable content, BLOCKED for an anti-bot or challenge page, INVALID_PAGE for content that does not match the requested platform, UNSUPPORTED_URL for page URLs whose host belongs to no supported platform, and TIMEOUT for fetch/parse operations exceeding the 20-second budget. Blocked-page fixtures use `blocked.html` or error JSON with an `expected.json` containing the corresponding error code.

**Error copy and actions (shared by the App and the extension).** User-facing copy is centralized per client but must stay consistent with this table:

| code | message（用户文案） | action（操作按钮） |
|---|---|---|
| `LOGIN_REQUIRED` | 需要先登录对应平台（小红书/Instagram/X） | `goLogin` → [去登录]（跳对应平台登录页） |
| `PRIVATE_OR_UNAVAILABLE` | 该帖子不存在、私密或已删除 | `backHome` → [返回首页] |
| `BLOCKED` | 请求被对方限制，请稍后再试 | `retry` → [重试] |
| `INVALID_PAGE` | 页面内容无法识别，可能已改版 | `retry` → [重试] + [复制诊断信息] |
| `UNSUPPORTED_URL` | 不支持的链接，请粘贴小红书/Instagram/X 帖子链接 | `repaste` → [重新粘贴]（聚焦输入框） |
| `TIMEOUT` | 网络超时，请检查网络后重试 | `retry` → [重试] |

**Blocked-page判定.** XHS: an anonymous fetch returns the generic shell whose `__INITIAL_STATE__` holds only global `appSettings` and no `noteDetailMap[<id>]` entry for the requested note, even though the note id may appear in links/meta — this is authenticated-only content, so the expected code is LOGIN_REQUIRED. Instagram: an anonymous fetch returns the logged-out shell (`PolarisLoggedOut*` route, `CurrentUserInitialData` with `USER_ID` 0) with no product object matching the shortcode-derived media id — likewise LOGIN_REQUIRED. X: an anonymous fetch returning a `TweetTombstone` with viewer/age restrictions or sensitive content returns LOGIN_REQUIRED. Only pages showing an explicit captcha/challenge interstitial use BLOCKED.

Resolution policy: always select the highest resolution available.

## Parser entrypoint design

**X fixture input is JSON rather than HTML.**
Unlike Xiaohongshu and Instagram where data is scraped from embedded state scripts inside the full HTML document, X (Twitter) in v1.4 utilizes Twitter's public syndication API (`https://cdn.syndication.twimg.com/tweet-result`) which returns a structured JSON payload directly.

**Entrypoint architecture:**
The parser exports both a unified dispatch function and individual platform functions:
1. `parse(input: string, pageUrl: string): string` — The single contract invoked by App WebView/JS runtime and browser extension.
2. `parseX(input: string | Record<string, unknown>, pageUrl: string): string` — Specialized X platform parser.

**Rationale for unified entrypoint with polymorphic `input`:**
- **Uniform Call-site Contract**: The App's `ParseService` and extension background scripts interact with one predictable function `EasySaveParser.parse(input, pageUrl)`. The client doesn't need platform-specific branching for JavaScript method invocations.
- **Graceful Input Handling**: For X URLs, `input` is the JSON response string from `cdn.syndication.twimg.com/tweet-result`. If non-JSON text (such as an HTML 404 Doge page) is passed, `parseX` safely catches the JSON parse exception and emits an appropriate error (`PRIVATE_OR_UNAVAILABLE` or `INVALID_PAGE`).
- **Clean Testability**: Exporting `parseX` separately allows TS unit tests and fixture runners to test X payload parsing directly without unnecessary wrapping.

## Xiaohongshu

**Source and paths.** Prefer the structured state exposed by the page: locate the note identified by the 24-character lowercase hex id in `window.__INITIAL_STATE__`, `window.__NEXT_DATA__`, or `window.__NUXT__`. The embedded state may contain non-JSON JS literals (`undefined` outside string literals): the preferred approach is to replace such literals with `null` and parse the whole state; only if that still fails, fall back to extracting the `noteDetailMap` subtree. The id appears in note page paths matching `/(explore|discovery/item|user/profile/[^/]+)/([a-f0-9]{24})` (case-insensitive). Candidate shapes include `noteDetailMap[id].note`, mobile `noteData.data.noteData`, and a note object containing `noteId`, `imageList`, or `video`. Author name is resolved from the note's user object in priority order `nickname`, `nickName`, `name`, `userName`; author id from `userId`, `user_id`, `id`, `redId`. Caption/body is `desc` (fallback `description`); `title` is taken when present; publish time is the note's `time` field in milliseconds (as `publishedAt`).

**URL rules.** For each entry in `imageList` (fallback `images`), the original image URL is resolved in priority order: `urlDefault`, then `url`, then `https://sns-img-qc.xhscdn.com/{traceId}` derived from a non-blank `traceId`. Skip entries with no usable URL. XHS CDN image URLs are normalized to their canonical original: strip the `!style` suffix (and anything after it), drop a leading `<date>/<32-hex>` prefix when present, and rewrite the remainder as `https://ci.xiaohongshu.com/{token}`. Non-XHS hosts are kept as-is. All output URLs use `https://`. For video, the original file is resolved first from an explicitly supplied `originVideoKey` (`video.consumer.originVideoKey`, fallback top-level `originVideoKey` on the video object) as `https://sns-video-bd.xhscdn.com/{key}`; only when no key is supplied are stream renditions used. Additional renditions are enumerated from `video.media.stream` and `video.stream` codec arrays, each contributing `masterUrl` plus `backupUrls` plus `url`. App-media payloads (`video.mediaV2`, a JSON string) use snake_case equivalents (`stream_type`, `stream_desc`, `master_url`, `backup_urls`) under its `stream` object. A stream entry is treated as watermarked when its type is 259 or 309, or its desc equals `WEB_LIVEPHOTO_19` (case-insensitive); watermarked renditions are deprioritized. A video note (see Note type) is emitted as a single `video` item whose `url` is the resolved original file; its cover image is not a separate item. A normal note's image entry paired with its own motion stream is emitted as `live`, with the video in `videoUrl` (resolved with the same originVideoKey-first priority).

**Note type.** The note `type` field distinguishes video notes from image/text notes: when `type` is blank, treat the note as `video` if a main video exists and `imageList` has at most one entry whose item has no `stream` object; otherwise treat it as `normal`.

**Fallback.** Walk nested objects with cycle protection and accept a matching note-shaped object. If structured state is absent, use embedded JSON scripts or the page's canonical/OG metadata for a single preview image, but do not claim a full media list.

**Risks.** XHS frequently changes state names, lazy-loads media, signs or expires CDN URLs, changes note URL formats, and may require login or anti-bot challenges. Live-photo fields and image URL variants are especially unstable.

## Instagram

**Source and paths.** Fetch the public post page (`/p/{shortcode}/`, `/reel/{shortcode}/`, `/reels/{shortcode}/`, `/tv/{shortcode}/` all normalize to `/p/{shortcode}/` for fetching; both `instagram.com` and `instagr.am` hosts are accepted) and inspect JSON-bearing `data-sjs` scripts matching `<script\b[^>]*\bdata-sjs[^>]*>(\{.+?\})</script>`. The shortcode uses Instagram's base64url alphabet `A-Za-z0-9-_`. Recursively find the product whose numeric `id`/`pk` matches the shortcode converted to a media id. The shortcode-to-media-id conversion MUST use arbitrary-precision integers (BigInt in TypeScript) because the value exceeds 64-bit float precision; fixed-width 64-bit integers can overflow on unexpected input and must be rejected rather than wrapped. A candidate object matches when it has any of `video_versions`, `carousel_media`, or `image_versions2`. Caption is `caption.text`; author is `user.username` or `owner.username`; carousel media is `carousel_media`; publish time is `taken_at` (seconds, as `publishedAt`).

**URL rules.** Images are selected from `image_versions2.candidates` (or `display_url` fallback); videos from `video_versions`. Always select the highest-resolution rendition and retain signed query parameters. Do not rewrite CDN URLs because signatures and expiry are meaningful.

**Fallback.** In v1 there is no OG fallback on post pages: when public JSON is unavailable, report private, deleted, login-gated, or empty pages as parse failures rather than returning an empty success. A profile URL may fall back to its `og:image`, but this is not a post result.

## X (Twitter)

**Data source and API.**
- Endpoint: `https://cdn.syndication.twimg.com/tweet-result?id={id}&lang=en&token={token}`
- Supported hosts: `x.com` and `twitter.com`.
- Tweet ID matching: `/(?:x|twitter)\.com\/(?:[^/]+)\/status\/(\d+)/i`.
- Token calculation: Derived deterministically from the numeric tweet ID (referenced from Vercel react-tweet & yt-dlp):
  `token = ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')`

**JSON field paths:**
- `id`: `id_str` (fallback `id`).
- `url`: Canonical post URL normalized to `https://x.com/{user.screen_name}/status/{id_str}`.
- `author`: `{ name: user.name, id: user.screen_name }`.
- `caption`: `text` (tweet text body, keeping newlines, links, and emojis intact).
- `title`: Omitted (tweets have no separate title).
- `publishedAt`: `created_at` string parsed into ISO 8601 UTC format (`YYYY-MM-DDTHH:mm:ssZ`).

**Media resolution rules:**
- Media entries reside in the root `mediaDetails` array.
- **Photos (`type === "photo"`)**:
  - Original image URL: Append `?name=orig` to `media_url_https` (e.g. `https://pbs.twimg.com/media/{key}.jpg?name=orig`).
  - Dimensions: `original_info.width` and `original_info.height`.
  - Emitted as `{ type: "image", url, width, height }`.
- **Videos (`type === "video"`)**:
  - Filter `video_info.variants` where `content_type === "video/mp4"`.
  - Sort descending by numerical `bitrate`. Select the variant with the highest bitrate.
  - `posterUrl`: Still cover image from `media_url_https?name=orig`.
  - `duration`: Video duration in seconds from `video_info.duration_millis / 1000`.
  - Dimensions: `original_info.width` and `original_info.height`.
  - Emitted as `{ type: "video", url: highestBitrateMp4Url, posterUrl, width, height, duration }`.
- **Animated GIFs (`type === "animated_gif"`)**:
  - Classified as `{ type: "video" }` in the unified model (X delivers GIFs as looping silent MP4 video).
  - Video URL: Selected from `video_info.variants` where `content_type === "video/mp4"`.
  - `posterUrl`: Still cover image from `media_url_https?name=orig`.
  - Dimensions: `original_info.width` and `original_info.height`.
- **Quote Tweets**:
  - When a post quotes another tweet (`quoted_tweet` present), only extract media from the top-level `mediaDetails` representing the post itself. Never merge `quoted_tweet.mediaDetails`.

**Error classification:**
- **`PRIVATE_OR_UNAVAILABLE`**:
  - HTTP 404 response or HTML error page;
  - Empty JSON object `{}`;
  - `__typename === "TweetTombstone"` with message indicating the post was deleted or is no longer available.
- **`LOGIN_REQUIRED`**:
  - `__typename === "TweetTombstone"` with text indicating viewer limits (e.g., "account owner limits who can view their Posts", age-gated, or sensitive content requiring authentication).
  - v1.4 does not perform WebView fallback; returns `LOGIN_REQUIRED` directly.

**Cloud hot-update configuration:**
To insulate against future changes in Twitter's syndication endpoint, `manifest.json` specifies:
- `platforms.x.endpoint`: URL template (`"https://cdn.syndication.twimg.com/tweet-result?id={id}&lang=en&token={token}"`)
- `platforms.x.tokenFormula`: Token calculation expression
- `headers.x`: Request headers (e.g. `User-Agent`)
- `platforms.x.enabled` & `platforms.x.notice`: Remote kill-switch and maintenance copy

This document describes behavior only; no reference implementation code is copied.
