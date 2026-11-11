# Build 32 / parser 1.4.13 handoff

## Delivery status

Both the APK and the parser change. Install build 32, then check the parser
channel for **1.4.13 / manifestVersion 9**; the APK already embeds it.

- Parser 1.4.13 alone (on build 31) supplies the ranked XHS download order
  (preview variants excluded) but not the size check, the "非原图" mark, the
  image probe log, the gallery, login or restore changes.
- Build 32 alone is impossible: it embeds 1.4.13.

Device verification remains pending; nothing below is a device verification
claim.

## 1. Xiaohongshu low-resolution images

**Root cause.** For every XHS image the parser returns `url` = original bucket
and `fallbacks` = [ci JPEG transcode, **WB_PRV preview** (`!nd_prv_*`), WB_DFT
(`!nd_dft_*`), bare ci]. The downloader uses fallbacks first for XHS
(`[...fallbacks, url]`), and every retry or stall recovery advances to the next
URL (`attempts % urls.length`, stall retries since 2026-10-27). So the first
attempt fetched the full-size JPEG transcode, but any failure or stall of it
made the second attempt download the **preview** — a small image saved as if it
were the original. Retrying again rotated back to a full-size URL, matching
"sometimes low-res, fine after a few re-downloads". The build 24 thumbnail
variants (`thumbnailUrl`, WB_PRV/H5_PRV for the grid) are a separate field and
were never download candidates; the preview in `fallbacks` was.

**Changes.**

- Parser (App adapter only; legacy `url`/`fallbacks` and all spec fixtures are
  unchanged): XHS image items get `downloadOrder`, ranked original resolution
  first — JPEG transcode of the original, original bucket, bare ci original —
  then the default-size variant (WB_DFT), then anything else. Every preview
  variant (`!nd_prv*`, WB_PRV, H5_PRV) is excluded.
- App: a parser-ranked `downloadOrder` replaces the site's url/fallbacks order.
  Images carry their declared width/height into the download job.
- Size check: after a background image download the header size is read
  (JPEG SOF, PNG IHDR, WebP VP8/VP8L/VP8X; no decoding). If the long side is
  below 80 % of the declared one, the file is set aside, the next candidate is
  fetched and `[V16DL] event=retry reason=low_resolution expected=WxH
  actual=WxH candidate=n/m` is logged. Only the largest small copy is kept;
  when no candidate is left (or the rest fail) it is saved and its history file
  is flagged `not_original`; cards show **非原图**. A full-size later candidate
  discards the kept copy.
- `[XhsImageProbe] image=i/n declared=WxH fields=<names> scenes=<imageScene
  names> candidates=<variants> selected=<variant>` per image (no URL).

**Already saved low-resolution files** are not touched. To find them: open the
image in the album's details and compare its size with the post (XHS images are
usually 1080 px or more on the long side; the preview is about 720 px or less),
or look for small files in the EasySave album. Delete the file (or the history
entry together with the file) and download the post again with build 32.

**Tests.** Extension: variant classification, order with and without an
original, no preview in the App result, legacy fields unchanged, probe output.
App: header sizes for JPEG/PNG/WebP, the 80 % rule, planning in parser order,
low-res retry, keep-largest with 非原图, no check without a declared size, probe
lines, and the real history page showing 非原图.

## 2. Saved images in the full-screen gallery

**Root cause.** `VerifiedAssetImage` with `isOriginal: true` (every local file
in the gallery) painted the enlarged thumbnail plus a spinner until the
original's first frame, a build 28 change meant for remote previews. Pages
outside the PageView are disposed; the recreated page re-ran the existence
check (an empty first frame) and, for originals larger than the image cache
budget, decoded again.

**Changes.** Local originals decode directly with a silent empty area while
decoding — no thumbnail placeholder and no indicator. Confirmed-present assets
are remembered for the session, so a revisited page renders at once. The
gallery keeps decoded originals in a bounded `DecodedImageKeeper` (5 images:
the current page, its neighbours and the last ones seen) and decodes the next
and previous image ahead. Remote previews (parse preview page and the overlay's
native preview) keep thumbnail + loading.

**Tests.** A local original never shows a loading indicator or requests a
thumbnail; in the real `GalleryBrowserPage` (image cache budget forced to zero)
the next page is decoded ahead and swiping back to seen pages does not decode
them again; keeper capacity. The swipe test fails when the keeper is disabled.

## 3. XHS login state after clearing app data

**Root cause.** `probeXhsSessions` always loaded both XHS pages in a WebView;
with no cookies neither page yields a readable account state, which combined to
"unknown". The Mine page used one shared checking flag, so "重新检查" showed
every row as checking although only XHS was probed.

**Changes.** Before loading pages, the session cookie *names* of both XHS
domains are checked: none → **未登录** at once (`[XhsLogin]
condition=no_session_cookie`), no page load. Only with a session cookie whose
page state cannot be read is the state "无法确认"; the row then shows both
**重新检查** and **去登录**. Re-checking marks and probes that platform only.
Other platforms already follow the cookie-name rule (no stateHook page check):
no session cookie → 未登录, cookie present → 已登录.

**Tests.** No cookie → invalid without a page; cookie detection on either
domain; page-state combination (true → valid, unreadable → unknown); other
platforms; the real Mine page with both buttons and a single-platform re-check.

## 4. Restore progress

The restore button is disabled for the whole flow ("恢复中…"); importing shows
a non-dismissible dialog "正在恢复 x / y 个帖子" with a progress bar, closed when
done; the summary lists restored posts (new / merged / skipped), files and files
not on this device. Tests: progress sequence, dialog text and non-dismissal,
summary, and the real `BackupRestorePage` flow (button blocked while the preview
sheet is open, progress visible during the import, summary afterwards).

## Validation

- Flutter **912/912** (`app/build/build32-flutter-final.log`).
- Android unit tests **105/105**, 27 classes, 0 skipped.
- Extension: TypeScript check, Vitest **263/263**, Node release checks **28/28**;
  candidate release and production builds pass.
- `dart analyze --no-fatal-warnings lib` exits 0; 59 diagnostics (61 before),
  none in new code.

## Release

- [CI 42356650931](https://github.com/joopererer/EasySave/actions/runs/42356650931)
  succeeds, **19/19 steps**, on tag `parser-v1.4.13` = `1ae7c32`.
- [Parser 1.4.13 Release](https://github.com/joopererer/EasySave/releases/tag/parser-v1.4.13):
  not draft or prerelease; parser.js **88,652 bytes** (SHA-256
  `a3f152c6812d39d1d48198617d33c4ef22af657744bc5063d3f8d4f1f076956a`),
  manifest.json **12,881 bytes** (SHA-256
  `29bbb9368f896a3eb373e1afcd81301eb475a8d46c80fd2c31c6d1d5c4dad999`).
- `tools/verify_v2_channel.mjs` with the App's public key: Release and master
  envelopes byte-identical; Ed25519, schema, parser hash, release URL and
  **1.4.13 / 9** pass. Anonymous public downloads of both assets and the raw
  master channel equal the authenticated readback.
- Published payload equals the APK builtin manifest; published parser equals
  the APK parser. Production SignedParserManifest verification,
  ParserReleaseStore activation and two fresh ParserManager starts pass
  (remote / 1.4.13, watermark 9).
- CI advanced master to **a938dde**, changing only `spec/v2/manifest.json`. No
  manual master push; the signing key stayed in CI. Evidence: `app/build/v1413/`.

## APK

`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build32-debug.apk`,
**173,707,689 bytes**, `com.james.easysave` **1.10.0 (32)**, built from
`1ae7c32f8ad23970ed8954b80ed39fd5c1b1a726`.
SHA-256 `13d4a81d8481f578c5d08ee326b55a62de153424a86732a9588c60b7f2db32d2`.
`apksigner verify` passes; certificate SHA-256
`7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484` (same as
builds 27–31). `tools/verify_build32_apk.py` passes: parser 1.4.13 / 9 bytes and
digest match the APK assets and the published release; 14 changed Dart sources
(gallery, verified image, keeper, history cards, Mine, restore page/dialog,
download manager, image size reader, auth, ...) are embedded byte-for-byte
(`app/build/build32/apk-verification.json`).

## Device retest steps

1. Cover-install build 32 without clearing data; confirm 1.10.0 (32) and parser
   1.4.13 / 9 (cloud check and restart persistence).
2. **XHS resolution**: download `xhslink.cn/o/488vg0Xs30N` and
   `xhslink.cn/o/30KMJ1uxH4i` several times (also on mobile data). In the album,
   image dimensions must match the post (no ~720 px previews). Export logs:
   `[XhsImageProbe]` shows `selected=jpeg` and no `preview` among candidates; a
   small file logs `[V16DL] event=retry reason=low_resolution` and is replaced.
   If a post only offers small images, its card shows **非原图**.
3. Find older low-resolution files (see section 1) and re-download them.
4. **Gallery**: open a saved multi-image post from history, swipe through and
   back: no blurry thumbnail, no spinner, already-seen images appear instantly.
   Remote preview (parse preview page, overlay preview) still shows the
   thumbnail and loading.
5. **Login**: clear app data (only if acceptable), open Mine: 小红书 shows
   **去登录**, not "无法确认". Log in; with weak network use the unknown state:
   both **重新检查** and **去登录** appear and re-checking only marks 小红书.
6. **Restore**: restore a backup with many posts: "正在恢复 x / y 个帖子" with a
   progress bar, the restore button shows "恢复中…" and cannot be tapped, the
   summary lists posts, files and 不在本机.
7. Regress XHS/IG/X/TikTok downloads, backup v2 export/restore, overlay
   "本地已有", and the build 29–31 items.
