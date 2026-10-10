# EasySave parsing specification

## Unified output

Fixture pairs used to validate this contract live under spec/fixtures/.

Parsers produce `{ platform, id, author, caption, items: [{ type: image|video|live, url, videoUrl? }] }`. `items` preserves source order; `live` represents a still image paired with its motion asset.

## Xiaohongshu

**Source and paths.** Prefer the structured state exposed by the page: locate the note identified by the 24-character id in `window.__INITIAL_STATE__`, `window.__NEXT_DATA__`, or `window.__NUXT__`. Candidate shapes include `noteDetailMap[id].note`, mobile `noteData.data.noteData`, and a note object containing `noteId`, `imageList`, or `video`. Author and caption come from the note's user/author object and `desc`.

**URL rules.** For each image, prefer the largest origin-quality URL in its image metadata and remove resizing/query transformations only when the host/path format is known to preserve the asset. For video, use the note's video URL. A paired image and video is emitted as `live`, with the video in `videoUrl`.

**Fallback.** Walk nested objects with cycle protection and accept a matching note-shaped object. If structured state is absent, use embedded JSON scripts or the page's canonical/OG metadata for a single preview image, but do not claim a full media list.

**Risks.** XHS frequently changes state names, lazy-loads media, signs or expires CDN URLs, changes note URL formats, and may require login or anti-bot challenges. Live-photo fields and image URL variants are especially unstable.

## Instagram

**Source and paths.** Fetch the public post page and inspect JSON-bearing `data-sjs` scripts. Recursively find the product whose numeric `id`/`pk` matches the shortcode converted from Instagram's base-64 alphabet. Caption is `caption.text`; author is `user.username` or `owner.username`; carousel media is `carousel_media`.

**URL rules.** Images are selected from `image_versions2.candidates` (or `display_url` fallback); videos from `video_versions`. Select the highest usable rendition and retain signed query parameters. Do not rewrite CDN URLs because signatures and expiry are meaningful. Reels/posts/tv URLs normalize to `/p/{shortcode}/` for fetching.

**Fallback.** Use OG image/video metadata for a single item when public JSON is unavailable. A profile URL may fall back to its `og:image`, but this is not a post result. Report private, deleted, login-gated, or empty pages as parse failures rather than returning an empty success.

**Risks.** Instagram changes script schemas and gates public data, CDN URLs expire, shortcode decoding can overflow for unexpected input, carousels mix media types, and regional/login/age restrictions can hide the product.

This document describes behavior only; no reference implementation code is copied.
