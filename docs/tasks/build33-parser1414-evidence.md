# Build 33 / parser 1.4.14 handoff

## Delivery status

Both the APK and the parser change.

- Install build 33 (`1.10.0 (33)`). It already embeds parser **1.4.14 /
  manifestVersion 10**, so nothing has to be fetched for the new behaviour.
- The cloud channel gets 1.4.14 / 10 from the `parser-v1.4.14` tag. Build 32 +
  1.4.13 does **not** contain the token copy, the automatic update check, the
  history/delete fixes or the overlay local preview.
- Device verification remains pending; nothing below claims a device result.

## What the user has to update

1. Install build 33 over build 32 (cover install; no data clear needed).
2. Confirm **我的 → 解析器版本** shows `1.4.14 (内置)` right after the first
   start. That value comes from the APK, so it is the ground truth for the
   "which version is on the phone" question (see problem 1).
3. Wait for CI to publish `parser-v1.4.14`, then press the refresh button once.
   It must report "当前已是最新解析器" and the log must show
   `event=check trigger=manual result=same remoteVersion=1.4.14
   remoteManifest=10 localManifest=10`.

## 1. Parser version report: 1.4.12 / 8 after installing build 32

**Verified from the APK.** `EasySave-1.10.0-build32-debug.apk`
(SHA-256 `13d4a81d…32d2`) contains
`assets/flutter_assets/assets/parser/builtin-manifest.json` with
`parserVersion=1.4.13`, `manifestVersion=9`, and a `parser.js` whose SHA-256
equals the manifest (`a3f152c6…956a`). Build 32 never embedded 1.4.12.

**Root cause of the log line.** `[ParserUpdate] event=activated
version=1.4.12 source=builtin manifestVersion=8` is a **line left behind by the
build 31 installation**. The device log (`v16dl.log`) is append-only across app
updates and lines carry no timestamp or build marker, so an activation logged by
the previous APK reads exactly like the current one. Build 31's APK embeds
`1.4.12 / 8` (verified from
`EasySave-1.10.0-build31-debug.apk`), which is exactly the reported pair.

**Changes.**

- `[ParserUpdate] event=session stream=<foreground|background> app=<version>
  builtinVersion=<v> builtinManifest=<n> activeVersion=<v> activeManifest=<n>`
  is written once per process at init. Everything after the last `event=session`
  line belongs to the running build, so a stale line can no longer be mistaken
  for the current state.
- Build-time gate: `extension/scripts/check_builtin_versions.js` fails the build
  (and `npm test`) when the bundled `builtin-manifest.json` `manifestVersion`,
  `parserVersion`, `sha256`, `parserUrl`, or the generated
  `lib/generated/parser_version.dart` disagree with
  `config/parser-release.json` and `spec/PARSER_VERSION`.
  `scripts/build_android_release.ps1` runs
  `scripts/verify_builtin_parser.ps1` before Gradle; the same script accepts
  `-ApkPath` and re-checks the values **inside the APK**. Negative cases are
  covered by `extension/scripts/builtin_versions.check.js`.

## 2. Automatic parser update check

**Before.** Only the cold start called `checkForUpdates()`, throttled to one day,
and there was no log line for a check that did not activate anything.

**Changes.**

- Startup (`trigger=startup`) and every return to the foreground
  (`trigger=resume`, from `MainShell.didChangeAppLifecycleState`) call the check;
  the minimum interval is now **6 hours** (`kAutomaticCheckInterval`) and is
  shared by both automatic triggers. The Mine page button stays
  `trigger=manual` and bypasses the interval.
- Every run writes exactly one line:
  `[ParserUpdate] event=check trigger=<startup|resume|manual>
  result=<newer|same|older|error|skipped> remoteVersion=<v> remoteManifest=<n>
  localManifest=<n> localVersion=<v> [reason=<interval|not_modified|http|verify|
  min_app_version|parser_download|manifest_url|format|exception>]`.
  `older` is a release the anti-rollback watermark refused.

## 3. Deleted post brought its old file rows back

**Root cause.** `HistoryDb.delete()` only set `is_deleted = 1`; `files_json`
stayed. The next download of the same post wrote its history with
`restoreDeleted: true` and merged `existing.files` into the new rows, so old rows
that were never re-saved came back. `isSavedHistoryFile()` also treated a stored
`mediaId`/`assetId` as proof of a file, so until the next album scan ran the
cards counted rows whose files no longer existed; the scan then corrected the
count, and the following placeholder write merged the rows again — hence
"4 selected shows 7, later correct, then wrong again".
The overlay path was not a second cause: the panel hands back exactly the typed
numbers (new Robolectric test), and the placeholder write stores zero rows; the
extra rows all came from the merge.

**Changes.**

- `delete()` clears `files_json` and `file_count` in the same transaction as the
  soft delete and the delete barrier. Nothing of a deleted post's file rows can
  be restored.
- `upsert` merge: a deleted record contributes **post-level information only**
  (title, author, saved time, items). Only rows confirmed in the album
  (`status == found`) join a write; `unknown`/`notFound` rows are dropped, and
  the log line now carries `kept=<n> dropped=<n>`.
- Display: `isSavedHistoryFile` is now exactly `status == found`.
  Post cards, home "最近保存", the viewer, share and the delete confirmation all
  read `record.savedFiles`, so an unconfirmed row is never counted — including
  the moment before the album scan finishes. A finished save writes
  `status: found` (the album accepted the file) instead of `unknown` when
  MediaStore returns no id, so a real save is never hidden.
- `syncRecord` no longer downgrades a confirmed row to `unknown` when the album
  cannot be read (limited permission); "cannot look" is not "file gone".
- One-time cleanup, database only (no album file is read, moved or deleted):
  schema version 7 runs `_cleanResidualFileRows`, which drops every file row of a
  soft-deleted record and, for active records, every row an album scan already
  marked `notFound`. Rows only `unknown` are kept as scan hints; they are never
  counted. Each rewrite logs
  `file rows cleaned source=migration post=… deleted=<0|1> from=<n> kept=<n>`.
- Re-association of an old file the user kept (`删除记录，保留文件`) still works:
  the downloader finds the album copy through MediaStore/provenance and writes a
  fresh confirmed row (test: "an album file the user kept is re-associated").

## 4. Overlay fullscreen preview of an already-saved image

**Before.** `SelectPanelView.showPreview` always requested the network original,
so a "本地已有" item showed the thumbnail, then a spinner, then the image.

**Changes.**

- `GalleryLocatorService.findDownloadedAssets` returns the album asset per saved
  index (the old `findDownloadedIndices` now delegates to it), and the overlay
  payload carries `savedMediaId`.
- `showPreview` decodes the album copy through the new
  `NativeLocalBitmap.decode` → `OrientedBitmap` (same sampling/EXIF path as the
  rest of the panel) and shows it **without** thumbnail placeholder or spinner.
  If MediaStore no longer serves the id, it logs
  `local preview unavailable, using network` and falls back to the network path,
  which keeps the spinner. Videos and "LIVE" items are unchanged.

## 5. Xiaohongshu link without xsec_token

**Root cause.** The terminal-page table maps xiaohongshu's `/404` route to
`POST_NOT_FOUND / 帖子不存在，或链接已失效`, and that route is also where a link
that was not produced by the share sheet lands, even when the post exists.

**Changes.** The signed site config gains
`load.accessTokenParams: ["xsec_token"]` and, on the 404 rule,
`missingTokenCode: TOKEN_REQUIRED` + the copy
`链接缺少访问令牌，请使用小红书 App 内“分享”得到的链接，或登录后重试`.
`terminalPageFailure` reads the **requested** post URL (`navigateStep` is given
`targetUrl`), because the 404 route drops the query string. An empty
`xsec_token=` also counts as missing. With a token the old copy is unchanged.
The App refuses a signed bundle that lacks the rule
(`parser_config_contract.dart`), so build 33 always has it: an active 1.4.13 is
replaced by the embedded 1.4.14 on first start.

## Recorded, not implemented (see `v1.11.md`)

- Mine page per-platform account status should refresh only the platform the
  user just came back from.
- "扫描非原图" tool: list saved XHS images that are visibly smaller than the
  post's declared size and re-download them in one tap.

## Tests

`flutter test` (app): **925 passed**. New: `test/history_delete_redownload_test.dart`
(8 cases: delete clears rows, re-download keeps only new items, repeated cycles
do not grow, merge ignores unconfirmed rows, display counts confirmed rows only,
overlay typed-number write, kept album file re-association, v6→v7 cleanup),
`test/xhs_missing_token_test.dart` (5 cases). Updated to the new intended
behaviour: `build28_history_identity_test.dart` (merge no longer keeps filename
guesses next to real files), `history_db_migration_test.dart` (same rule),
`parser_hooks_test.dart` (token rule), `backup_service_test.dart` unaffected
(`statusOf` now judges by stored rows, so an unlocated file no longer marks a
whole post as a failed download).

`npm test` (extension): **263 vitest + 33 node** tests, including the new
builtin-version gate and its negative cases.

Gradle unit tests: **all pass**, including the new
`SelectPanelNumberSelectionTest` (typed numbers are the only indices handed back,
no thumbnails expanded) and `SelectPanelSavedPreviewTest` (saved image comes from
the album with the spinner hidden; a vanished id decodes to null).

`flutter analyze` on the changed files: no errors (only the project's existing
style infos). `git diff --check`: clean.

## Release

Parser **1.4.14 / manifestVersion 10**. `parser.js` bytes are unchanged
(`a3f152c6812d39d1d48198617d33c4ef22af657744bc5063d3f8d4f1f076956a`,
88,652 bytes): only the manifest payload (site config + schema) changed.

## APK

- Debug (delivered, source-verified):
  `app/build/app/outputs/flutter-apk/EasySave-1.10.0-build33-debug.apk`,
  **173,720,677 bytes**, SHA-256
  `e3e6ac969cdec4b8d25c1da23898c1187aa00304de060041a7d76e853840fa3f`.
- Release: `app/build/app/outputs/flutter-apk/EasySave-1.10.0-build33-release.apk`,
  **69,014,628 bytes**, SHA-256
  `07f60b9bdd650875c156df26e5418486b63ba073db1a781b2851e43ed157a2da`.
- `aapt dump badging`: `com.james.easysave`, versionName **1.10.0**,
  versionCode **33**. `apksigner verify` passes; certificate SHA-256
  `7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484` (same as
  builds 27–32).
- `scripts/verify_builtin_parser.ps1 -ApkPath` (both APKs): parser **1.4.14 /
  manifestVersion 10**, embedded SHA-256 matches the manifest and the tree.
- `tools/verify_build33_apk.py` (debug): the manifest carries
  `accessTokenParams` + `missingTokenCode`; 15 changed Dart sources are embedded
  byte-for-byte; dex contains `savedMediaId`, `NativeLocalBitmap`, and the
  fallback log string (`app/build/build33/apk-verification.json`).
- `tools/verify_build33_release_apk.py` (release): the AOT snapshot contains the
  token copy (UTF-16LE), the `event=check`/`event=session`/`kept=`/cleanup log
  markers, and the dex keeps `savedMediaId`
  (`app/build/build33/apk-verification-release.json`). R8 renames classes in
  release builds, which is why the release check uses string markers.

## Device retest steps

1. Cover-install build 33; do not clear data. Mine must show `1.10.0 (33)` and
   parser `1.4.14 (内置)`. The device log must start a new block:
   `[ParserUpdate] event=session … builtinVersion=1.4.14 builtinManifest=10`.
2. Open Mine, press the parser refresh once: `event=check trigger=manual
   result=same remoteVersion=1.4.14 remoteManifest=10 localManifest=10`
   (before the tag is published: `result=newer` then the same line).
3. Background the app for a few minutes and return: log shows
   `event=check trigger=resume` — either `skipped reason=interval` or `same`.
4. **History counts.** For `488vg0Xs30N` and `30KMJ1uxH4i`: delete the post with
   its files, then re-download 3, then 4, then 5 different images (also via the
   overlay with the preview panel closed and numbers typed). Each time the card
   and the viewer show exactly the number just downloaded; nothing appears and
   disappears. Log: `file rows written source=download post=… count=<n>
   kept=0 dropped=<previous>`.
5. **Old file kept.** Delete one post with "只删除记录，保留文件", download the
   same post again: the kept image is associated (no duplicate in the album) and
   appears once in the history.
6. **Overlay local preview.** Open the overlay panel on a post with some images
   already saved: tapping "本地已有" opens the album copy immediately — no
   thumbnail placeholder, no spinner. A not-saved item still shows the
   thumbnail + spinner.
7. **Token copy.** Paste
   `https://www.rednote.com/explore/6a1bcbdf0000000038020654` (no
   `xsec_token`): the message must be
   `链接缺少访问令牌，请使用小红书 App 内“分享”得到的链接，或登录后重试`.
   A shared link (`xhslink.cn/...` with a token) that is really gone keeps
   `帖子不存在，或链接已失效`.
8. Regress the four platforms, backup v2 export/restore, and the build 29–32
   items (low-resolution probe, gallery, login state, restore progress).
