# EasySave parsing specification

## Unified output

Fixture pairs used to validate this contract live under spec/fixtures/.

Parsers produce `{ platform, id, url, author: { name?, id? }, title?, caption?, publishedAt?, items: [{ type: image|video|live, url, videoUrl?, width?, height? }] }`.
`platform` is `xhs` or `instagram`. `url` is the canonical post URL.
`items` preserves source order. `live` represents a still image paired with its
motion asset via `videoUrl`. In v1, `live` is only an image+video pair; no
motion-photo synthesis is performed.

v1 scope exclusions: comment-section images, Stories, and OG fallback on post
pages. When structured parsing fails, return an explicit parse error instead of
a partial or empty success.

**Error model.** Parse failures use { code, message } and never return a successful empty result. The v1 codes are LOGIN_REQUIRED for a login wall or authenticated-only page, PRIVATE_OR_UNAVAILABLE for private, deleted, or unavailable content, BLOCKED for an anti-bot or challenge page, INVALID_PAGE for content that does not match the requested platform, and UNSUPPORTED_URL for page URLs whose host belongs to no supported platform. Blocked-page fixtures use `blocked.html` with an `expected.json` containing the corresponding error code.

**Blocked-page判定.** XHS: an anonymous fetch returns the generic shell whose `__INITIAL_STATE__` holds only global `appSettings` and no `noteDetailMap[<id>]` entry for the requested note, even though the note id may appear in links/meta — this is authenticated-only content, so the expected code is LOGIN_REQUIRED. Instagram: an anonymous fetch returns the logged-out shell (`PolarisLoggedOut*` route, `CurrentUserInitialData` with `USER_ID` 0) with no product object matching the shortcode-derived media id — likewise LOGIN_REQUIRED. Only pages showing an explicit captcha/challenge interstitial use BLOCKED.

Resolution policy: always select the highest resolution available.

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

**Risks.** Instagram changes script schemas and gates public data, CDN URLs expire, shortcode decoding can overflow for unexpected input, carousels mix media types, and regional/login/age restrictions can hide the product.

This document describes behavior only; no reference implementation code is copied.
