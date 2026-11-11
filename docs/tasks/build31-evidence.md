# Build 31 handoff: v1.10 2c backup v2 (APK only)

## Delivery status

Install build 31. The parser module does not change (still **1.4.12 /
manifestVersion 8**), so no parser update is needed and no tag was created.
Device verification remains pending; nothing below is a device verification
claim. Field reference and v1→v2 differences: `v1.10.md` "备份格式 v2".

## Step 0: dependency upgrade (commit 41de3fd)

- `docs/provenance-spec` submodule → **v0.1.8** (`4746ec6`); App
  `provenance_dart` git ref → **v0.2.4** (resolved `0bcabca`), lock updated.
  Same reference style as before (submodule commit, git tag ref).
- Normalization entry points: provenance URLs are built by provenance_dart's
  `ProvenanceBuilder` (`normalizeUrl`); backup `canonicalUrl` uses the same
  function. The App's own canonical (`SiteRegistry.canonicalUrl`, from the site
  configuration) equals the spec output for every valid note in
  `urls-0.1.8.json`: rednote.com and xiaohongshu.com links of one note give the
  same canonical URL and sourceId, and `sameSavedOrigin` treats them as one
  origin.
- Old records: links are compared after re-normalizing both sides
  (`sameCanonicalUrl`) in `isLinkKnown` and `findRecordByLink`; stored values
  (including an old `rednote.com` canonical) are never rewritten. Written XMP is
  not migrated.
- Two App tests that pinned 0.1.7 behavior were updated: the rednote canonical
  now equals the xiaohongshu one, and repeated query parameters are kept.
- Gate: Flutter **881/881**.

## Step 1: backup schema v2

**Writer** (`backup_service.dart`, `backup_model.dart`): schemaVersion 2; each
post keeps platform, sourceId, canonicalUrl (spec 0.1.8, no query), originalUrl
(as saved, with xsec_token), title, author, caption, AI label fields, savedAt,
status (success / partial / failed) and failureReason; each file keeps
itemIndex, mediaType, filename, relativePath, size, assetId, mediaIdHint,
savedAt (plus stored itemCount / capturedBy). No media, thumbnail or cover URL
is written; originalUrl is the only URL with a query.

- File sizes: recorded at download time (`HistoryFile.size`, stored in
  files_json without migration); older rows get the MediaStore size at export
  through a new batched `mediaSizes` call on the native bridge.
- Failed posts: a new `download_error` column (database version 6, additive
  migration) keeps the short failure reason of the last download. A failed or
  partial post is exported with its status; after restore, history shows
  "下载失败（原因），点击重试" (or "下载失败，点击重试" without a reason) even
  though no download batch exists, and the retry re-parses originalUrl.
- **Restore** (v1 and v2): `BackupRestoreMatcher` links each file by
  provenance (sourceId + itemIndex, or assetId) → name convention → mediaIdHint
  verified by name and size. A candidate whose provenance names another post or
  item is excluded, each album file is linked at most once, files already
  located on the device are kept, unmatched files become not-on-device
  (`notFound`). v1 `items` and file `provenance` URLs are dropped. Restoring
  twice gives the same history.
- Three-layer backup unchanged; the SAF read-back check now requires
  schemaVersion 2.

**Tests** (`build31_backup_v2_test.dart`, 9; `build31_restored_failed_post_widget_test.dart`, 2):
URL scan of the whole export (only originalUrl / canonicalUrl, only originalUrl
with a query, no media host, no cookie or session names, key audit);
v2 export → restore round trip; failed post round trip; v1 restore with URLs
dropped and an unverified mediaId ignored; no A→B linking (hint, generic name,
contradicting provenance); idempotent double restore; mediaId hint only with
matching name and size; size comparison; v5 → v6 migration; the real
`HistoryPage` rendering a restored failed post with a retry.

**Size**: 40 posts / 160 files with signed CDN URLs: v1 layout **227,985
bytes**, v2 **89,447 bytes** (0.39×).

Existing tests that pinned v1 were updated to the v2 contract (version numbers,
no `items`, provenance facts on the file instead of the nested object).

## Validation

- Flutter **892/892** (`app/build/build31-flutter-final.log`).
- Android unit tests **105/105**, 27 classes, 0 skipped
  (`build31-android-final.log`).
- `dart analyze --no-fatal-warnings lib` exits 0; 61 diagnostics, unchanged,
  none in new code.
- Parser and extension are unchanged; their suites were not rerun.

## APK

`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build31-debug.apk`,
**173,685,709 bytes**, `com.james.easysave` **1.10.0 (31)**, built from
**e507ba4f2c6df72ecab84abca81853854ea0f9a7**.
SHA-256 `73d29d6556fbfb9be4727946eacad11547b3726360da2c961edbf234e173426f`.
`apksigner verify` passes; certificate SHA-256
`7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484` (same as
builds 27–30). `tools/verify_build31_apk.py` passes: builtin parser 1.4.12 / 8
unchanged; nine changed Dart sources (backup service/model/matcher/SAF,
history_db, url_normalizer, clipboard_guard, history_cards, history_page) are
embedded byte-for-byte; the DEX contains the bridge's `mediaSizes`
(`app/build/build31/apk-verification.json`).

## Device retest steps

Keep a copy of an existing (v1) backup before starting: in Mine → 备份与恢复,
export once with build 30 if none exists yet, or copy the newest file from the
SAF backup folder.

1. Cover-install build 31 without clearing data; confirm 1.10.0 (31) and parser
   1.4.12 / 8. History must open normally (database upgrades to version 6).
2. **Export**: 备份与恢复 → 导出备份. Open the file in a text viewer and check:
   `"schemaVersion": 2`; each post has `canonicalUrl`
   (`https://www.xiaohongshu.com/explore/<id>` also for rednote links) and
   `originalUrl` (xsec_token kept); `status` is `success`, `partial` or
   `failed`; files have `size`, `assetId`, `mediaIdHint`; there is no `items`,
   `thumbnailUrl`, `provenance`, and no `xhscdn.com`, `twimg.com`,
   `cdninstagram`, `tiktokcdn` or `sign=` anywhere. Compare the size with the
   v1 file. A failed download (e.g. the storage-full X post) appears with
   `"status": "failed"`.
3. **Restore the old (v1) backup** on the same phone: it must import without
   error; history shows the same posts; saved files open; posts without files
   show "下载失败，点击重试". Export again: the new file is v2 and has no media
   URL.
4. **Restore the new (v2) backup**: run it twice; post count, file count and
   cards must be identical after each run (no duplicates). Export logs and check
   `[BackupRestore] event=done ... viaProvenance= viaFilename= viaMediaIdHint=
   notOnDevice=`.
5. On a failed post card tap "下载失败，点击重试": it re-parses the original link
   and opens the preview to download.
6. Optional, on a second device or after reinstalling: restore the v2 backup;
   files present in the album are linked (thumbnails open), missing ones show as
   not on this device; no card shows another post's image.
7. Regress: XHS rednote and xiaohongshu links of the same note are recognized as
   one post (already-downloaded prompt), and download / overlay behaviour from
   builds 29–30.
