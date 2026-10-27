# Changelog

## Unreleased

- Floating ball select panel: type item numbers directly (`1,3,5-8`) without loading previews; thumbnails are off by default and load on demand.
- Downloads: a history record is written as soon as a download starts, with a progress overlay on the card; a failed enqueue no longer strands the other files.
- Downloads: a 90 s watchdog imports, retries or fails stuck files, and the gallery import has a 60 s timeout, so a batch can no longer hang at 50%.
- Added a download queue page (history top bar) with per-file cancel/retry and batch delete; the preview page shows progress with cancel/retry for its post.
- Backup restore is no longer hard-blocked by unfinished downloads; it offers "go to download queue" or "cancel all and continue".
- History viewer: no item is pre-selected any more (positional indices were compared with post item indices).

## v1.7.0 - 2026-10-22

- Added provenance metadata writing and preservation for JPEG, PNG, and WebP images.
- Added C2PA detection and safe skip behavior without generating sidecars.
- Added URL normalization, gallery history rebuild, cancellation support, album selection, and legacy backfill flows.
- Completed unit/conformance coverage and device verification for JPEG downloads from Xiaohongshu, Instagram, and X.
- Documented known limitations and the AI metadata verification procedure.
