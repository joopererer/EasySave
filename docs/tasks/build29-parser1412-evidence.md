# Build 29 / parser 1.4.12 corrective handoff

## Delivery status

Both the APK and the parser change. Install build 29, then check the parser
channel for **1.4.12 / manifestVersion 8**. The APK already embeds this parser.

- A parser-only update (1.4.12 on build 28) gives audio-aware XHS stream ranking
  and the X restriction codes/copy, but not the logged-in X retry, probe logs,
  the no-audio download retry, the overlay "本地已有" fix or the history layout fix.
- APK-only without the parser is impossible: build 29 embeds 1.4.12.

Device verification remains pending; nothing below is a device verification claim.

## 1. Overlay "本地已有" (background engine)

**Root cause.** App preview and overlay already call the same function,
`GalleryLocatorService.findDownloadedIndices(post)` → `matchPostItems`, with the
same platform, post ID and 1-based → 0-based itemIndex conversion; the history
rows are read straight from SQLite, so the foreground write is visible to the
background engine. The difference is the locator singleton's per-engine state:
album permission is only read by the foreground start-up (`main.dart`
`ensurePermission`). In the overlay's background engine `_permission` stays
`notDetermined`, so `hasAccess` is false, the album is never scanned and
`AssetEntity.fromId` is skipped for rows with a mediaId. Every item is reported
as not saved. Rows without mediaId/assetId (the build 28 rule) depend on the
album scan, which never ran there; a background index made earlier would also
predate files the foreground saved later.

**Change.** `matchPostItems` reads the permission state when it has none (both
engines). The overlay's select path calls
`findDownloadedIndices(post, refreshAlbum: true)`: it re-reads permission and
rescans the used albums (not the whole library) every time the panel opens.
The result is never stored in the parse cache; `[SavedLookup] engine= permission=
scanned= refreshed= albumAssets= items= saved=` is logged per decision.

**Tests** (`build29_overlay_saved_lookup_test.dart`): the same post and history
rows are judged in a foreground state and in a fresh background state; both give
{1,3,5}. A background index scanned before the foreground save is refreshed.
Removing a file between two panel opens changes the result.

## 2. History waterfall after reordering

**Finding.** `MasonryGridView` (flutter_staggered_grid_view 0.7.0) keeps each
child's column and offset in render parent data. Cards are keyed `wf-<id>`
(stable), grouped by date; the user report says pull-to-refresh and tab switches
keep the broken layout while a layout toggle (which recreates the grid render
object) fixes it. Widget tests with the real page, a real re-save (new item,
`userSave`) and a move across date groups did **not** reproduce the hole in the
test environment, so the exact device sequence is not proven.

**Change.** New `HistoryMasonryGrid` keys the grid by the ordered item keys. Any
order or membership change (move to top, delete, insert) creates a new render
object, the same operation that fixed it on the device; progress-only rebuilds
keep the existing one. Used by both the posts and the all-media waterfalls.

**Tests** (`build29_history_masonry_reorder_test.dart`): the render object is
replaced on move/delete/insert and retained on a progress rebuild; both columns
are packed after the last card moves to the top; the real `HistoryPage` re-save
of the last post puts it first and the next post beside it.

## 3. X restricted posts

**Data source (root cause).** X uses `load.mode = json`: the App fetches the
anonymous syndication endpoint `cdn.syndication.twimg.com/tweet-result` with Dart
`http.get` and only the declared headers. The request carries **no cookies**.
The X login page and every parse WebView use the same Android WebView cookie
store (no incognito, `CookieManager.instance()`), but the syndication request
does not go through a WebView, so the X login could never take effect. This
explains `condition=validate code=PRIVATE_OR_UNAVAILABLE` while logged in.

**Change.**

- Site configuration: X `load.entryTemplate = https://x.com/i/status/{id}` and a
  desktop `load.userAgent`. Payload validation requires https, `{id}` and a host
  inside the site's routes; the App checks the host again before loading.
- Order (as in cobalt): guest syndication first. If it fails with
  LOGIN_REQUIRED / AGE_RESTRICTED / PROTECTED / PRIVATE_OR_UNAVAILABLE and the
  X session cookie name is present, the logged-in post page is loaded in the
  shared cookie store. A parser hook wraps the page's own fetch/XHR and keeps
  only `TweetResultByRestId` / `TweetDetail` responses. The App never reads,
  copies or joins cookie values; the page's own requests carry them.
- Not logged in: unchanged guest behavior. Session page without post data or
  timeout: the guest answer is kept.
- Mapping (parser module): `TweetUnavailable` reason NsfwLoggedOut →
  LOGIN_REQUIRED, NsfwViewerHasNoStatedAge → AGE_NOT_SET, NsfwViewerIsUnderage →
  AGE_RESTRICTED, Protected → PROTECTED, other → PRIVATE_OR_UNAVAILABLE;
  `TweetTombstone` starting with "Age-restricted" → AGE_RESTRICTED, other
  tombstones → PRIVATE_OR_UNAVAILABLE; `TweetWithVisibilityResults` is unwrapped
  to `result.tweet`.

| Code | 中文 | English |
| --- | --- | --- |
| LOGIN_REQUIRED | 该内容需要登录 X 才能查看 | Log in to X to view this post. |
| AGE_NOT_SET | 该内容需要你的 X 账号先设置出生日期（年龄）后才能查看 | Add your date of birth to your X account to view this post. |
| AGE_RESTRICTED | 该帖子有年龄限制，需要登录已完成年龄验证的 X 账号才能查看 | This post is age-restricted. Log in with an age-verified X account to view it. |
| PROTECTED | 该帖子来自受保护的账号，只有获准的关注者可以查看 | This post is from a protected account; only approved followers can view it. |
| PRIVATE_OR_UNAVAILABLE | 帖子不可用：可能已删除、设为私密，或需要登录 X 才能查看 | Post unavailable: it may be deleted, private, or require logging in to X. |

When the **logged-in page** still answers AGE_RESTRICTED, the message names the
X setting “显示可能包含敏感内容的媒体” (Settings → Privacy and safety → Content
you see). When the logged-in page answers as logged out, the message says the X
session has expired. A guest answer never produces these two messages.

**Diagnostics.** `[XLogin] event=state status=valid|invalid|unknown basis=
session_cookie_name_present|session_cookie_name_absent|cookie_store_error
store=shared_webview_cookie_manager cookies=auth_token:0|1` (names only) and
`[XLogin] event=decision source=guest_only|session_page
guestRequestCookies=none sessionRequestCookies=webview_managed`.
`[XProbe] source=syndication|graphql shape= typename= wrapped= reason=
tombstone="<first 40 chars>" fields=<field names> mediaCount=`. No post text,
URL, query value or cookie value is logged.

**Tests.** Additive fixtures `spec/fixtures/x/build29-*.json` (no stated age,
protected, age-restricted tombstone, other unavailable) and
`spec/fixtures/x/graphql/` (each unavailable shape, TweetResultByRestId with
photo+video, TweetDetail with visibility wrapper and note text). Extension tests
cover each shape, copy, probe, page hooks and the guest-restricted → session
data path; Dart tests cover the retry decision, foreign entry hosts, the
cookie-name state and probe log sanitizing. The build 28 unit test that mapped
the age-restricted tombstone to LOGIN_REQUIRED was updated to AGE_RESTRICTED as
this round requires; the build 28 spec fixtures are unchanged and still pass.

**Not proven.** Whether the reported post returns NsfwLoggedOut, an age
tombstone or another shape is only visible in the device `[XProbe]` lines.

## 4. Xiaohongshu videos without sound

**Finding.** The parser always preferred `originVideoKey` (the original upload),
then the highest-resolution clean stream, ignoring audio fields. The original
upload declares no audio fields, and an editor soundtrack can exist only in the
transcoded streams; stream lists also vary between page loads, which matches
"sometimes silent, re-download fine".

**Change.**

- Stream audio state from `audioCodec` / `audioChannels` / `audioBitrate`:
  any positive → yes, all empty/zero → no, none present → unknown.
- Ranking: clean before watermarked; audio yes > unknown > no; the original
  upload before an equally unknown stream; then resolution, then bitrate. Other
  clean candidates not known to be silent become the video item's `fallbacks`.
- Downloads try a video primary first (`[url, ...fallbacks]`). After a background
  download completes, `mp4HasAudioTrack` reads only box headers and the moov box
  (`trak/mdia/hdlr` = `soun`, 64-bit and moov-at-end supported). A file without a
  sound track is discarded and the next candidate is downloaded with
  `[V16DL] event=retry reason=no_audio_track index= candidate=n/m`. The last
  candidate, Live Photo clips and unreadable files are kept.
- App preview uses the parser's first video URL, so it follows the same ranking.
  The post-download file check is not run for online preview.
- `[XhsStreamProbe] candidate=i/n bucket= streamType= codec= size= bitrate=
  audio= audioCodec= audioChannels= audioBitrate= audioFields= watermarked=
  selected=` per candidate.

**Tests.** Additive fixture `spec/fixtures/xhs/build29_video_audio_stream.*`
(silent 1080p, 720p AAC, watermarked AAC, original key); the existing
`xhs_video` fixture output is unchanged. Unit tests cover audio states, ranking,
probe output, MP4 files with and without `soun`, moov at the end, and the retry
decision.
