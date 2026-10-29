# Frozen metadata baseline

Source commit: 24fb900 (before the platform migration).

- url_normalizer_24fb900.dart: original app/lib/metadata/url_normalizer.dart.
- builders_24fb900.dart: original provenanceForBatchItem and _shouldWriteAuthorId from app/lib/services/download_manager.dart, plus _buildProvenance from app/lib/services/history_backfill_service.dart.

Only imports, the two entry-point names, and Dart formatting were adapted.
No manifest helpers are used by these frozen builders. The harness supplies the
same DownloadBatch/HistoryRecord/HistoryFile/AssetEntity inputs to both versions.
The dependency and DownloadBatch.totalItems are unchanged by this migration.

site_metadata_migration_test.dart compares the complete XMP field maps and
actual JPEG/MP4 round trips. Only generated assetId, capturedAt and metadataDate
are omitted; publishedAt remains compared. Its separately named Instagram
exception removes exactly prov:authorId from the OLD output, asserting the old
value and the absence of the new value. All other cases require full equality.
Do not regenerate these fixtures from migrated code.
