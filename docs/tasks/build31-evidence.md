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
