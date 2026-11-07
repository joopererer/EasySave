# Build 30 handoff (APK only; parser unchanged at 1.4.12 / 8)

## Delivery status

Install build 30. The parser module does not change (still **1.4.12 /
manifestVersion 8**, already published), so no parser update is needed and no
parser tag was created. Device verification remains pending; nothing below is a
device verification claim. Last v1.10 fix round; new ideas are recorded in
`v1.11.md`.

## 1. Overlay "本地已有" still missing

**Root causes.**

1. photo_manager reads its permission through the Activity; the overlay's
   background engine has none, so it always reports `notDetermined`
   (`[SavedLookup] engine=background permission=notDetermined scanned=0`). The
   build 29 re-read could not change that.
2. Found while fixing: the `easysave/media` channel (file header / XMP reads,
   album lookup) was registered only in `MainActivity`. In the overlay engine
   every provenance check failed, so items would have been rejected even with
   permission.
3. Found while fixing issue 2: `assetByBaseName` looked up a name without
   extension in a map keyed by MediaStore display names, which carry one, so
   the import idempotency guard never matched a real file.

**Choice: native MediaStore in both engines** (not a foreground round trip). It
works whether or not the App is open, needs no cross-engine protocol, and the
Dart matching (`matchPostItems`) stays identical; only the source of the album
index differs.

- New `MediaStoreBridge` (Kotlin), registered by `MainActivity` and by
  `HostService` on `easysave/media`. `permissionState` uses
  `ContextCompat.checkSelfPermission`: Android 12 and below
  `READ_EXTERNAL_STORAGE`; Android 13+ `READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO`;
  Android 14+ `READ_MEDIA_VISUAL_USER_SELECTED` alone → `partial`.
  `savedMediaIndex` queries the Images and Video collections of EasySave's used
  albums (`bucket_display_name`), returning id, name, size, dimensions, relative
  path and `owned` (`OWNER_PACKAGE_NAME` = this app). Header, album and scan
  calls moved into the bridge so both engines have them.
- Own files without permission: on Android 10+ MediaStore returns files whose
  owner is the querying app even without read permission, so EasySave's saves
  are visible; `owned=` in the log counts them. Android 7–9 needs the read
  permission for any query (the bridge reports `error=security`). Files saved
  before a reinstall lose their owner and need the permission.
- When photo_manager has no access (either engine), the locator builds its index
  natively and judges presence from it; with access it scans as before.
- `[SavedLookup] engine= method=plugin|native permission=<actual> pluginPermission=
  scanned= refreshed= albumAssets= owned= items= saved=`.

**Tests.** `build30_overlay_native_lookup_test.dart`: plugin `notDetermined`
with the native index finds the saved items; foreground (plugin) and background
(native) give the same set; a file missing from MediaStore is not reported and a
rescan sees it again; no bridge degrades to nothing saved.
`MediaStoreBridgeTest.kt`: permission mapping for Android 12/13/14 and the
selection.

## 2. Large download with storage full

**Root causes (from the code; no device log was supplied).**

1. The whole import (provenance rewrite of the video plus its album copy) ran
   under a fixed **60 s** timeout. For a ~1 GB video it times out, the job is
   marked failed, and the copy keeps running and lands in the album: a playable
   album file, a failed queue item.
2. A batch with zero successes deleted the post's history row
   (`discardEmptyPlaceholder`), so a failed post disappeared from history.
3. `historyWritten` was set before the history write; a write error (SQLite
   cannot write on a full disk) was never retried or logged.
4. The "already in the album" guard never matched (see 1.3 above), was disabled
   in the overlay engine, and read the album file through `originFile`, which
   copies a large video again. Every retry therefore downloaded and saved a new
   1 GB copy (filling the disk further) and tended to time out again, which is
   the most likely reason a failure reappeared shortly after a retry.
5. No free-space check and no disk-full mapping existed.

**Changes.**

- Preflight: before a background download, a HEAD request (no redirect, no
  cookies) reads Content-Length; with free space below `size × 2 + 256 MiB` the
  job fails at once with `STORAGE_FULL` and "存储空间不足，需要约 X GB". Unknown
  size or unknown free space never blocks. Free space comes from the bridge
  (`StatFs` of cache and external storage, the smaller one).
- ENOSPC / SQLITE_FULL during download, import or session transfer map to
  `STORAGE_FULL` (no retry loop on a full disk).
- Every failure removes the job's temp files (task directories of all attempts,
  the finished file and its sidecar): `[V16DL] cleanup bytes=<n> index=`.
- Import budget grows with size (60 s + 1 s per 8 MiB). An import that still
  outlives it is followed to the end: if the album copy succeeds the job becomes
  done and history is written (`late import done`); if it fails, temp files are
  cleaned.
- A post whose download failed stays in history; only an all-canceled batch
  removes its placeholder. The card shows "下载失败（原因），点击重试" (reason:
  存储空间不足, HTTP 403, 保存超时, ...).
- History writes (placeholder and terminal) are tried three times with
  `[HistoryDb] event=write_retry/write_recovered/write_failed reason=`; after a
  final failure the batch keeps owing its row and is retried 30 s later.
- Idempotent retry: before downloading again, the album is checked for a file of
  this post item (base name, provenance from header bytes, and the MediaStore
  size equal to the size handed to the album when known). If found it is linked,
  history is written and no download starts (`retry reused album copy`). A retry
  first waits for a still-running timed-out import.

**Tests** (`build30_storage_full_download_test.dart`,
`build30_failed_post_history_widget_test.dart`): disk full before the download
(nothing fetched, STORAGE_FULL copy, post in history); ENOSPC while writing (temp
files removed, `cleanup bytes=4196`); album write succeeds while the database is
full (three retries logged, row written automatically once writes succeed, no
failure left); retry links a complete album copy without downloading and leaves
no failed batch; an incomplete copy (size differs) downloads again; a timed-out
import finishing later is recorded; the real `HistoryPage` shows
"下载失败（存储空间不足），点击重试" with a retry control.

`background_download_saf_test` "empty_history" previously used a failed download
to obtain an empty history; failed posts now stay visible by requirement, so the
scenario uses a canceled download, which still leaves history empty and keeps
the guard under test. Auto-backup still counts any active row (as it already did
for in-progress placeholders).

## Validation

- Flutter **876/876** (`app/build/build30-flutter-final.log`). An earlier full run
  had one failure (the SAF guard test above) before its scenario was updated; it
  is not counted.
- Android unit tests **105/105**, 27 classes, 0 skipped
  (`build30-android-final.log`).
- `dart analyze --no-fatal-warnings lib` exits 0; 61 diagnostics, unchanged from
  build 29, none in new code.
- Parser, extension and spec files are unchanged in this round; their suites were
  not rerun.

## APK

`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build30-debug.apk`,
**173,661,053 bytes**, `com.james.easysave` **1.10.0 (30)**, built from
**e629237d0e98c37bbc235a04e102ef2350edc2d0**.
SHA-256 `e09ba83ad407960e5fd90a8a17d4b233de5e062aa5e2e0e163627c44e4c7b470`.
`apksigner verify` passes; certificate SHA-256
`7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484` (same as
builds 27–29). `tools/verify_build30_apk.py` passes: builtin parser 1.4.12 / 8
bytes and digest unchanged; six changed Dart sources (including
`history_cards.dart`, `history_page.dart`, `gallery_locator_service.dart`) are
embedded byte-for-byte; the DEX contains `MediaStoreBridge` and its companion
registration, `savedMediaIndex`, `storageInfo`, `mediaSize` and the owner column
(`app/build/build30/apk-verification.json`).

The commits are local on feature/v1.10; nothing was pushed (no parser change,
so this round only builds build 30).

## Device retest steps

1. Cover-install build 30 without clearing data; confirm 1.10.0 (30) and parser
   1.4.12 / 8 (no parser update expected).
2. 本地已有: in the App download 3 items of `xhslink.cn/o/2UN2COpb1Ov`, then open
   the overlay "选择下载" for the same link. The same 3 items must be marked. Export
   logs: `[SavedLookup] engine=background method=native permission=<granted|
   partial|denied> owned=` with `saved=3`. Repeat with album permission revoked
   (Settings → Apps → EasySave → Photos) — own saves must still be marked.
3. Storage: with little free space, download the ~1 GB X video. Expect an
   immediate failure "存储空间不足，需要约 X GB", the post in history with
   "下载失败（存储空间不足），点击重试", no growing temp data, and
   `[V16DL] preflight ... result=STORAGE_FULL` plus `cleanup bytes=`.
4. Free space, tap the history card to retry: it must download, appear once in
   the album and in history, and no new failure may appear afterwards. If an
   earlier attempt had already put the file in the album, the retry must link it
   (`retry reused album copy`) instead of downloading again.
5. Large file with enough space: the import may take minutes; the queue must not
   show a failure while the album copy completes (or, if it does time out,
   `late import done` must follow and the failure clear).
6. Meanwhile an XHS download must not stall. Regress XHS, IG, X and TikTok
   downloads and the build 29 items (waterfall reorder, X login data, XHS audio).
