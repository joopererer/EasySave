# EasySave Metadata Implementation

This document describes how EasySave implements the [Provenance Metadata Spec v0.1](../docs/provenance-spec/SPEC.md). It does not repeat the spec content; read the spec first for field definitions, storage formats, and conformance requirements.

---

## 1. Overview

EasySave writes provenance metadata to downloaded media files so they remain traceable even when:
- The app database is cleared or migrated
- Files are copied to another device or cloud storage
- Users organize files in Windows Explorer, macOS Finder, or photo management apps

**Implementation**: Pure Dart byte manipulation. XMP parsing, merging, generation, and segment insertion/replacement for JPEG (APP1), PNG (iTXt), and WebP (XMP chunk) are all done in Dart without native dependencies. This enables conformance tests to run directly in `flutter test`.

Metadata is written **before** saving to the device gallery. Videos are not written in v1.7 (deferred to future versions).

---

## 2. Fields We Write

### 2.1 Required Fields (Every Downloaded Image)

| Field | Source | Notes |
|---|---|---|
| `prov:schema` | Constant `"0.1"` | Current spec version |
| `prov:assetId` | UUID v4 (generated once, stored in HistoryDb `files_json`) | Never modified after first write; preserved across re-downloads |
| `prov:capturedAt` | Download completion timestamp | ISO 8601 with timezone (device local time) |
| `prov:capturedBy` | `"EasySave/{version}"` | e.g. `"EasySave/1.7.0"` |
| `xmp:MetadataDate` | Current timestamp | Updated every time metadata is written or modified |

**assetId lifecycle**: Generated once at first download. Stored both in the file's XMP (`prov:assetId`) and in HistoryDb's `files_json` (per-file). On re-download of the same item, the HistoryDb lookup yields the existing `assetId` and the file is written with the same value — so copies across devices share the same identity.

### 2.2 Source Fields (Network Downloads)

| Field | Unified Model | Required | Notes |
|---|---|---|---|
| `prov:sourceUrl` | Normalized post URL (see §3) | Yes | Normalized **at metadata write time**, not at parse time |
| `prov:platform` | `post.platform` | Yes | `xiaohongshu`, `instagram`, `x` |
| `prov:sourceId` | `post.id` | Yes | Post/tweet native ID |
| `prov:itemIndex` | 1-based position in `post.items` | Multi-item only | Must reflect position in the original post (not the user's selection order) |
| `prov:itemCount` | `post.items.length` | When available | |
| `prov:authorId` | `post.author.id` | When available | |
| `prov:publishedAt` | `post.publishedAt` | When available | Converted to ISO 8601 with timezone; use UTC (Z suffix) if original has no timezone |
| `prov:pairId` | — | **No** | Deferred; not written in v1.7 |

**Note on `itemIndex`**: If the user selects items 2 and 5 from a 9-image post, the written `itemIndex` values are **2** and **5** (original positions), not **1** and **2**.

### 2.3 Standard Fields (When Available)

| Field | Unified Model | Write? | Notes |
|---|---|---|---|
| `dc:title` | `post.title` | Yes — only if present | Do NOT synthesize from caption |
| `dc:creator` | `[post.author.name]` | Yes — only if present | Single-element ordered list |
| `dc:description` | `post.caption` | Yes | Truncate at **2000 chars** with `…` |
| `dc:subject` | — | **No** | User's own tag field; EasySave v1.7 reads and preserves it but never writes |
| `xmp:Rating` | — | **No** | Reserved for future user feature |
| `dc:source` | Normalized `post.url` (see §3) | Yes | Mirror of `prov:sourceUrl`; normalized at write time |
| `photoshop:Credit` | `"{author.name} / {platformDisplayName}"` | Yes | e.g. `"某作者 / 小红书"` |

**Platform display names for `photoshop:Credit`**: `小红书` for xiaohongshu, `Instagram` for instagram, `X` for x.

---

## 3. Link Normalization

Implemented in Dart (`app/lib/metadata/url_normalizer.dart`). Must pass all cases in `docs/provenance-spec/test-vectors/urls.json`.

### 3.1 General Rules
1. Remove tracking parameters: `utm_*`, `fbclid`, `gclid`, `igsh`, `igshid`, `si`, `spm`, `share_*`, `shareRedId`, `xsec_token`, `xsec_source`, `apptime`, `author_share`, `xhsshare`, `track_code`, `app_platform`, `app_version`, `ignoreEngage`, `dlrf`, `xtok`, `img_index`
2. Remove URL fragments (`#...`)
3. Short links (`xhslink.com`, `t.co`, `vm.tiktok.com`) require network expansion — done at parse time before normalization
4. Lowercase scheme and hostname; preserve path case

### 3.2 Platform-Specific Patterns

**Note**: Link normalization happens **at metadata write time**. `post.url` in HistoryDb and the unified model remains the original URL (preserving `xsec_token` and other parameters needed for re-parsing and opening in browser).

| Platform | Normalized Format |
|---|---|
| xiaohongshu | `https://www.xiaohongshu.com/explore/{noteId}` |
| instagram | `https://www.instagram.com/p/{shortcode}/` (Reels also normalized to `/p/`) |
| x | `https://x.com/i/status/{tweetId}` (no username) |

---

## 4. Storage Format & Byte-Level Operations

### 4.1 Format-Specific Storage

| Format | Storage Method | Implementation |
|---|---|---|
| JPEG | APP1 segment (`0xFFE1`) with XMP header `http://ns.adobe.com/xap/1.0/\0` | Dart byte scan + insert/replace; use ContentResolver with content URI (mode "wt") for gallery files |
| PNG | `iTXt` chunk, keyword `XML:com.adobe.xmp`, no compression | Dart chunk manipulation; XMP may be at file end, must read complete file |
| WebP | RIFF `XMP ` chunk (requires VP8X extended header + XMP flag bit) | Dart RIFF traversal; XMP may be at file end, must read complete file; simple format upgraded to VP8X with XMP flag |
| GIF | Sidecar file `*.xmp` | Deferred (v1.7 writes JPEG/PNG/WebP only) |
| MP4 | Sidecar file `*.xmp` | Deferred |
| HEIC/AVIF/RAW | Sidecar file `*.xmp` | Deferred |

### 4.2 Byte Preservation Requirement

**Pixel-level**: After XMP write, decoding the image (using any standard decoder) must produce **identical pixels** to the original.

**Byte-level**: For formats that support in-place metadata segment manipulation (JPEG APP1 replace, PNG iTXt replace), all bytes **outside the modified metadata segment** must be **byte-for-byte identical** to the original file.

For WebP where VP8X header upgrade is needed, the compressed bitstream must be preserved exactly; only the VP8X flags byte and chunk list are modified.

### 4.3 C2PA Detection

Before writing metadata, check for existing C2PA content credentials:

| Format | Detection Method | Action |
|---|---|---|
| JPEG | Scan for APP11 segment (`0xFFEB`) containing JUMBF data with label containing `"c2pa"` | **Skip** write, log `"C2PA detected in {filename}"` |
| PNG | Scan for `caBX` chunk | **Skip** write, log |
| WebP | Scan RIFF chunks for `"C2PA"` box | **Skip** write, log |

**Sidecar note**: Per SPEC §4.3, C2PA-signed files should use sidecar. v1.7 does **not** generate sidecar files; it skips the write and logs instead.

### 4.4 XMP Merge Rules (Preservation of Existing Metadata)

When writing to a file that already has XMP:

1. Read the entire existing XMP packet (from APP1 / iTXt / RIFF XMP chunk)
2. Parse all fields from all namespaces
3. Modify **only** the fields defined in this spec (§2)
4. **Never overwrite** existing `prov:assetId` (must preserve the original)
5. **Never overwrite** existing capture fields (`prov:sourceUrl`, `prov:platform`, `prov:sourceId`, `prov:itemIndex`, etc.)
6. User fields (`dc:title`, `dc:subject`, `xmp:Rating`) are **preserved** unless they are from this spec's own write (i.e., EasySave does not overwrite tags set by Lightroom or Windows Explorer)
7. All other namespaces and fields (e.g., `photoshop:Headline` from a third-party tool) are **preserved unchanged**
8. After modification, write back the complete XMP packet

### 4.5 Write Failure Handling

Metadata write failures **must not** block download or gallery save:
- File is saved to gallery regardless of metadata write success
- Error is logged with tag `MetadataWriter`
- User is **not** shown an error dialog
- History record is still created with all fields

---

## 5. Field Mapping (Unified Model Only)

All metadata fields come from the unified `ParsedPost` model. **No platform raw JSON paths are used.**

| Metadata Field | Unified Model Field | Notes |
|---|---|---|
| `prov:platform` | `post.platform` | String: `xiaohongshu`, `instagram`, `x` |
| `prov:sourceId` | `post.id` | Post/tweet ID string |
| `prov:sourceUrl` | Normalized `post.url` | Normalized at **write time** (§3); stored URL in HistoryDb/model is original |
| `prov:itemIndex` | `post.items.indexOf(item) + 1` | 1-based; position in **original post**, not download selection order |
| `prov:itemCount` | `post.items.length` | Total media count |
| `prov:authorId` | `post.author.id` | Stable user ID (may be null) |
| `prov:publishedAt` | `post.publishedAt` | Converted to ISO 8601 with timezone; use UTC (Z suffix) if original lacks timezone |
| `dc:title` | `post.title` | Written only if non-null and non-empty |
| `dc:creator` | `[post.author.name]` | Written only if non-null; single-element list |
| `dc:description` | `post.caption` | Truncated at 2000 chars; may be null |
| `photoshop:Credit` | `"{post.author.name} / {platformDisplayName}"` | Format `"{name} / {platform}"` |

**Fields not written in v1.7** (require future unified model additions):
- `dc:subject` — would need tag extraction in parser
- `xmp:Rating` — requires user UI
- `prov:pairId` — requires Live Photo pairing logic in parser

**To request a new field**: open an issue describing the need, then implement in the TS parser following `spec/parsing.md` + PARSER_VERSION workflow. Do NOT add raw platform JSON paths to the Dart metadata layer.

---

## 6. Integration Points

### 6.1 Download Flow (Foreground & Background Engines)

Both engines share the same `DownloadManager` (`app/lib/services/download_manager.dart`) and `HistoryDb` (`app/lib/services/history_db.dart`). Metadata write is called in `_finishFile()` after download completes and before/after `saveToGallery()`:

```
_download complete
  → write XMP to temp file (if image && setting enabled && !C2PA)
  → saveToGallery(temp or original path)
  → write HistoryDb record (with assetId from files_json)
```

The metadata write happens on the **same isolate** as the download (both foreground and background engines). No cross-engine communication needed.

### 6.2 Background Engine

The background engine (`app/lib/background/background_entry.dart`) uses the same `DownloadManager.instance`. The `_finishFile` call path is identical; no separate implementation needed.

### 6.3 Settings

New boolean setting `saveProvenanceInImages` (key: `saveProvenanceInImages`, default: `true`) in `AppSettings` (`app/lib/services/settings.dart`). When `false`, skip all XMP write operations but still write `assetId` to HistoryDb.

---

## 7. Gallery Rebuild & Backfill

### 7.1 Rebuild History from Gallery

**UI Entry**: "我的 → 设置 → 从相册重建历史"

**Algorithm**:
1. Request `photo_manager` permission if not granted
2. Scan EasySave album using `GalleryLocatorService.scanAlbum()` (already implemented)
3. For each `AssetEntity` in the album:
   - Read XMP from the file (via `photo_manager` file path)
   - If `prov:platform` + `prov:sourceId` are present → group by `(platform, sourceId)`
   - Within each group, sort by `prov:itemIndex` ascending
4. For each group:
   - Check if `HistoryDb` already has a record for `(platform, sourceId)`
   - If **exists**: merge files (update `mediaId`, `itemIndex`, `filename`, `status`; preserve existing fields)
   - If **not exists**: create new `HistoryRecord` with all extracted metadata
5. Use transaction to prevent duplicates (UPSERT based on unique `(platform, sourceId)`)
6. Show progress: `n / total files` with estimated time
7. Show result: `"{count} records processed, {new} new, {merged} merged, {skipped} skipped (no provenance metadata)"`

**Implementation location**: `app/lib/services/history_rebuild_service.dart`

### 7.2 Backfill Metadata to Old Files

**UI Entry**: "我的 → 设置 → 为旧文件补写来源信息"

**Algorithm**:
1. Query `HistoryDb` for all records with at least one file having `status == FileStatus.found`
2. For each record with a linked `mediaId`:
   - Try to open the file for writing via `photo_manager` asset path
   - If **writable**:
     - Read existing XMP from file
     - Extract `assetId` priority: **file XMP → HistoryDb files_json → newly generated**
     - Build provenance metadata from `HistoryRecord`
     - Use `capturedAt` from `files_json[i].savedAt` (original download time), not current time
     - Write XMP using the same logic as §4
     - If `assetId` was newly generated, write it back to `HistoryDb.files_json`
     - Log success
   - If **not writable** (scoped storage restriction):
     - Use `MediaStore.createWriteRequest` (same pattern as `MediaDeleteService` for `MediaStore.createDeleteRequest`) to batch-request write permission for all failed files
     - If **user grants**: write metadata to the authorized files
     - If **user denies**: increment skipped counter
3. Show result: `"{success} files updated, {auth} required permission, {skipped} skipped"`

**Note**: `MediaStore.createWriteRequest` is the same native channel pattern already used in `MediaDeleteService`. See `MainActivity.kt` for the Android-side implementation.

---

## 8. Testing

### 8.1 Unit Tests (flutter test)

All conformance tests run without native plugins or emulators:

**Test location**: `app/test/metadata/`

| Test File | Coverage |
|---|---|
| `url_normalizer_test.dart` | All cases in `docs/provenance-spec/test-vectors/urls.json` |
| `xmp_reader_test.dart` | Read test: `xhs-item3.jpg`, `ig-item2.png`, `x-single.webp`, `no-metadata.jpg` |
| `xmp_writer_test.dart` | Round-trip test: write → read → assert fields match |
| `xmp_preserve_test.dart` | Preservation test: existing `photoshop:Headline` survives write |
| `asset_id_immutability_test.dart` | Write with assetId A → write again with B → assert A |
| `pixel_preservation_test.dart` | Decode before → write → decode after → assert pixels identical |
| `c2pa_detection_test.dart` | For each format, test file with C2PA marker → assert skip |

**Test vectors**: Read directly from `docs/provenance-spec/test-vectors/` using relative paths (do not copy into the app). Use `Directory.current.path` or a test-only root constant.

### 8.2 C2PA Test Fixtures

Constructed locally in `app/test/metadata/fixtures/` (not committed to the spec repository):

| File | Format | Construction |
|---|---|---|
| `c2pa_jpeg.jpg` | JPEG | Minimal JPEG with APP11 JUMBF segment containing `c2pa` label |
| `c2pa_png.png` | PNG | Minimal PNG with `caBX` chunk |
| `c2pa_webp.webp` | WebP | Minimal WebP with RIFF `C2PA` chunk |

These files are small (under 1KB), valid at the binary level, and contain the C2PA detection signatures. They are used only to verify that the C2PA detector correctly identifies and skips these files.

### 8.3 Integration Tests (Physical Device)

1. Download a multi-image Xiaohongshu post
2. `adb pull` one file from the gallery
3. `exiftool -xmp:all` to verify all provenance fields
3. Windows Explorer → Properties → Details: verify **Title** and **Authors** readable (JPEG format)

### 8.4 AI Metadata Verification

Find one post marked as "AI generated" by its platform, download it, and verify that:
1. **Before** EasySave metadata write: inspect for AI provenance fields (`IPTC:DigitalSourceType`, C2PA manifest, etc.)
2. **After** EasySave metadata write: re-inspect and confirm all AI-related metadata is **byte-for-byte identical**

**Report in `docs/tasks/v1.7.md`**:
- Platform and post identifier (or a description if links are ephemeral)
- AI metadata fields found (names and values)
- Confirmation of preservation after write (or any discrepancies found)

---

## 9. File Locations in Codebase

| Component | Path | Description |
|---|---|---|
| URL normalizer | `app/lib/metadata/url_normalizer.dart` | Link normalization + unit tests |
| XMP reader | `app/lib/metadata/xmp_reader.dart` | Read XMP from JPEG/PNG/WebP (pure Dart) |
| XMP writer | `app/lib/metadata/xmp_writer.dart` | Write/merge XMP to JPEG/PNG/WebP (pure Dart) |
| XMP model | `app/lib/metadata/xmp_model.dart` | Dart class matching SPEC §7 JSON representation |
| C2PA detector | `app/lib/metadata/c2pa_detector.dart` | Binary signature detection per format |
| Metadata service | `app/lib/metadata/metadata_service.dart` | Orchestrates read/write, format routing, C2PA check |
| History rebuild | `app/lib/services/history_rebuild_service.dart` | Gallery scan → HistoryDb rebuild |
| Settings extension | `app/lib/services/settings.dart` | Add `saveProvenanceInImages` setting |
| Download manager hook | `app/lib/services/download_manager.dart` | Call `MetadataService` in `_finishFile()` |
| Background entry | `app/lib/background/background_entry.dart` | Same `_finishFile` path (no separate code) |
| Unit tests | `app/test/metadata/` | Conformance + round-trip + pixel preservation |
| C2PA fixtures | `app/test/metadata/fixtures/` | Small files with C2PA signatures for detection tests |
| Report | `docs/tasks/v1.7.md` | Test results, format support matrix, known limits |

---

## 10. Known Limitations

| Limitation | Reason | Workaround |
|---|---|---|
| Video (MP4) metadata not written | MP4 `uuid` box requires fragmented MP4 handling | Deferred; user sees provenance in HistoryDb and Windows Explorer (via sidecar in future version) |
| GIF/HEIC/AVIF/RAW sidecar not generated | These formats do not support embedded XMP; sidecar generation deferred | Deferred |
| WebP: files without VP8X header need header upgrade | Simple WebP format lacks metadata flags | Upgrade to VP8X with XMP flag bit; compressed bitstream preserved |
| C2PA-signed files are skipped | Embedding XMP invalidates the signature | In future: write to sidecar instead |
| Scoped storage restricts writes to files not created by EasySave | Android 11+ behavior | `MediaStore.createWriteRequest` for batch permission grant; user may deny |
| JPEG XMP write modifies APP1 segment | In-place APP1 replace is byte-identical for data; quantization tables unchanged | Pixel-level decode identical per §4.2 |

---

## 11. Changelog

| Date | Change | Reason |
|---|---|---|
| 2026-10-20 | Initial draft for v1.7 | Implementing provenance-spec v0.1 |
| 2026-10-20 | Revise implementation to pure Dart | Conformance tests must run in `flutter test` |
| 2026-10-20 | Restrict field mapping to unified model only | Consistency; no platform-specific code paths |
| 2026-10-20 | Drop dc:subject write, drop title synthesis | Per user clarification |
| 2026-10-20 | Add C2PA test fixtures in app/test/metadata/fixtures/ | Not stored in spec repository |
| 2026-10-20 | Clarify assetId lifecycle: stored in HistoryDb files_json | Enables re-download reuse and cross-device identity |
