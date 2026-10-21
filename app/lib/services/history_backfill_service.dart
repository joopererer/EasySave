// Copyright 2026 EasySave. All rights reserved.
// Service for backfilling provenance metadata to old files.
// See spec/metadata.md §7.2

import 'dart:convert';
import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../metadata/metadata_service.dart';
import '../metadata/xmp_model.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'media_delete_service.dart';

/// Result of a backfill operation.
///
/// [totalFiles] is every HistoryFile across every record (the universe this
/// run considered). The remaining counts partition that universe exactly:
/// totalFiles == success + authRequired + alreadyHasMetadata + fileNotFound +
/// noWritePermission + formatNotSupported + skippedVideo + skippedNotLocated +
/// otherError. Every file that contributes to one of these counters also has
/// a corresponding DevLog line explaining why.
class BackfillResult {
  /// Every HistoryFile examined, including ones filtered out before the
  /// per-file write attempt (videos, un-locatable files, etc).
  final int totalFiles;

  /// Files that were actually attempted (passed all pre-filters and didn't
  /// already have metadata). Kept for backward-compatible display as
  /// "X/total written".
  final int total;

  final int success;
  final int authRequired;
  final int alreadyHasMetadata;
  final int fileNotFound;
  final int noWritePermission;
  final int formatNotSupported;

  /// Video files (mp4 etc) - provenance is only embedded in images.
  final int skippedVideo;

  /// Files with no mediaId (or a mediaId that no longer resolves) that
  /// GalleryLocatorService also failed to locate by filename/postId.
  final int skippedNotLocated;

  final int otherError;

  const BackfillResult({
    required this.totalFiles,
    required this.total,
    required this.success,
    required this.authRequired,
    required this.alreadyHasMetadata,
    required this.fileNotFound,
    required this.noWritePermission,
    required this.formatNotSupported,
    required this.skippedVideo,
    required this.skippedNotLocated,
    required this.otherError,
  });

  int get skipped =>
      alreadyHasMetadata +
      fileNotFound +
      noWritePermission +
      formatNotSupported +
      skippedVideo +
      skippedNotLocated +
      otherError;

  @override
  String toString() {
    final parts = <String>[
      '$success/$total written',
      if (authRequired > 0) '$authRequired required permission',
      if (alreadyHasMetadata > 0) '$alreadyHasMetadata already had metadata',
      if (fileNotFound > 0) '$fileNotFound file not found',
      if (noWritePermission > 0) '$noWritePermission no write permission',
      if (formatNotSupported > 0) '$formatNotSupported format not supported',
      if (skippedVideo > 0) '$skippedVideo video (not applicable)',
      if (skippedNotLocated > 0) '$skippedNotLocated not located in gallery',
      if (otherError > 0) '$otherError other errors',
    ];
    return parts.join(', ');
  }
}

/// Service for backfilling provenance metadata to old files.
class HistoryBackfillService {
  HistoryBackfillService._();

  static final HistoryBackfillService instance = HistoryBackfillService._();

  static const _logTag = 'HistoryBackfill';

  /// Backfill provenance metadata to files that don't have it.
  /// 
  /// Algorithm:
  /// 1. Query HistoryDb for all records
  /// 2. For each file in each record:
  ///    - Try to locate asset by mediaId first
  ///    - If no mediaId or asset not found, use GalleryLocatorService to locate by filename/postId
  ///    - Check if file already has XMP provenance (real check, not just assetId presence)
  ///    - Skip video files (only process images)
  ///    - If not: try to write metadata directly
  ///    - If not writable, request permission via MediaStore.createWriteRequest
  /// 3. Show result summary with breakdown by skip reason, logging every file
  Future<BackfillResult> backfill({
    void Function(int current, int total, String filename)? onProgress,
  }) async {
    final db = await HistoryDb.instance();
    final records = await db.recent(limit: 10000); // Get all records

    var totalFiles = 0;
    var success = 0;
    var authRequired = 0;
    var alreadyHasMetadata = 0;
    var fileNotFound = 0;
    var noWritePermission = 0;
    var formatNotSupported = 0;
    var skippedVideo = 0;
    var skippedNoMediaId = 0;
    var skippedNotFound = 0;
    var otherError = 0;

    // Collect all files needing backfill
    final filesToBackfill = <_BackfillItem>[];

    // Ensure gallery is scanned for locating files without mediaId
    final locator = GalleryLocatorService.instance;
    if (!locator.scanned) {
      await locator.scanAlbum();
    }

    for (final record in records) {
      for (final file in record.files) {
        totalFiles++;
        
        // Skip video files - only process images
        if (!file.isImage) {
          skippedVideo++;
          DevLog.write(_logTag, 'Skipped (video): ${file.filename}');
          continue;
        }

        // Try to get asset by mediaId first
        AssetEntity? asset = file.mediaId != null 
            ? locator.getAssetById(file.mediaId) 
            : null;

        // If no mediaId or asset not found, try to locate by filename/postId
        if (asset == null) {
          if (file.mediaId == null || file.status != FileStatus.found) {
            asset = locator.locateAsset(file, record.postId);
            if (asset == null) {
              skippedNoMediaId++;
              DevLog.write(_logTag, 'Skipped (no mediaId, not found in gallery): ${file.filename}');
              continue;
            }
            // Found via locate - log and continue processing
            DevLog.write(_logTag, 'Located in gallery (no prior mediaId): ${file.filename} -> ${asset.id}');
          } else {
            fileNotFound++;
            DevLog.write(_logTag, 'Asset not found by mediaId: ${file.filename} (mediaId: ${file.mediaId})');
            continue;
          }
        }

        // Get file path
        File? filePath;
        try {
          filePath = await asset.file;
        } catch (e) {
          fileNotFound++;
          DevLog.write(_logTag, 'Failed to get file path for ${file.filename}: $e');
          continue;
        }

        if (filePath == null || !await filePath.exists()) {
          fileNotFound++;
          DevLog.write(_logTag, 'File not accessible: ${file.filename}');
          continue;
        }

        // Check if file already has provenance metadata (real check)
        try {
          final existing = MetadataService.readProvenance(filePath.path);
          if (existing != null && existing.sourceUrl != null) {
            alreadyHasMetadata++;
            DevLog.write(_logTag, 'Already has metadata: ${asset.title}');
            continue;
          }
        } catch (e) {
          otherError++;
          DevLog.write(_logTag, 'Error reading provenance from ${asset.title}: $e');
          continue;
        }

        filesToBackfill.add(_BackfillItem(
          asset: asset,
          filePath: filePath.path,
          record: record,
          file: file,
        ));
      }
    }

    final total = filesToBackfill.length;
    DevLog.write(_logTag, 'Backfill candidates: $total files (from $totalFiles total)');
    DevLog.write(_logTag, 'Skipped: video=$skippedVideo, noMediaId=$skippedNoMediaId, alreadyHas=$alreadyHasMetadata');

    // Process files in batches
    final batchSize = 20;
    for (var i = 0; i < filesToBackfill.length; i += batchSize) {
      final batch = filesToBackfill.skip(i).take(batchSize).toList();

      for (final item in batch) {
        onProgress?.call(
          i + batch.indexOf(item) + 1,
          total,
          item.asset.title ?? 'unknown',
        );

        final result = await _backfillFile(item);
        if (result.status == _BackfillStatus.success) {
          success++;
        } else if (result.status == _BackfillStatus.authRequired) {
          authRequired++;
        } else if (result.status == _BackfillStatus.fileNotFound) {
          fileNotFound++;
        } else if (result.status == _BackfillStatus.noWritePermission) {
          noWritePermission++;
        } else if (result.status == _BackfillStatus.formatNotSupported) {
          formatNotSupported++;
        } else {
          otherError++;
        }
      }
    }

    return BackfillResult(
      totalFiles: totalFiles,
      total: total,
      success: success,
      authRequired: authRequired,
      alreadyHasMetadata: alreadyHasMetadata,
      fileNotFound: fileNotFound,
      noWritePermission: noWritePermission,
      formatNotSupported: formatNotSupported,
      skippedVideo: skippedVideo,
      skippedNotLocated: skippedNoMediaId,
      otherError: otherError,
    );
  }

  Future<_BackfillStatusResult> _backfillFile(_BackfillItem item) async {
    final record = item.record;
    final file = item.file;
    final asset = item.asset;

    // Build provenance from history record, using savedAt from files_json as capturedAt
    final provenance = _buildProvenance(record, file, asset);
    if (provenance == null) {
      DevLog.write(_logTag, 'Failed to build provenance for ${asset.title}');
      return _BackfillStatusResult(_BackfillStatus.otherError);
    }

    // Try to write directly
    try {
      final result = await MetadataService.embedProvenance(
        filePath: item.filePath,
        provenance: provenance,
        checkC2pa: true,
      );

      if (result.success) {
        // Update assetId in HistoryDb
        await _updateAssetId(record, file, provenance.assetId);
        DevLog.write(_logTag, 'Wrote provenance to ${asset.title}');
        return _BackfillStatusResult(_BackfillStatus.success);
      }

      // Categorize error
      if (result.error?.contains('Permission denied') == true ||
          result.error?.contains('denied') == true) {
        // Try to request permission
        final granted = await MediaDeleteService.instance.requestWriteAccess([
          MediaRef(mediaId: asset.id, isImage: asset.type == AssetType.image),
        ]);

        if (granted) {
          // Retry write after permission granted
          final retryResult = await MetadataService.embedProvenance(
            filePath: item.filePath,
            provenance: provenance,
            checkC2pa: true,
          );

          if (retryResult.success) {
            await _updateAssetId(record, file, provenance.assetId);
            DevLog.write(_logTag, 'Wrote provenance after auth: ${asset.title}');
            return _BackfillStatusResult(_BackfillStatus.success);
          }
        }

        return _BackfillStatusResult(_BackfillStatus.authRequired);
      }

      if (result.error?.contains('format') == true ||
          result.error?.contains('Format') == true ||
          result.error?.contains('unsupported') == true) {
        DevLog.write(_logTag, 'Format not supported: ${asset.title}');
        return _BackfillStatusResult(_BackfillStatus.formatNotSupported);
      }

      DevLog.write(_logTag, 'Write failed for ${asset.title}: ${result.error}');
      return _BackfillStatusResult(_BackfillStatus.otherError);
    } catch (e) {
      DevLog.write(_logTag, 'Error writing provenance to ${asset.title}: $e');
      return _BackfillStatusResult(_BackfillStatus.otherError);
    }
  }

  XmpProvenance? _buildProvenance(
    HistoryRecord record,
    HistoryFile file,
    AssetEntity asset,
  ) {
    // Parse items from record
    List<MediaItem>? items;
    if (record.itemsJson != null) {
      try {
        final decoded = jsonDecode(record.itemsJson!);
        if (decoded is List) {
          items = decoded
              .map((raw) => MediaItem.fromJson(
                    (raw as Map).cast<String, dynamic>(),
                  ))
              .toList();
        }
      } catch (_) {}
    }

    // Fallback: create minimal item list
    items ??= [
      MediaItem(
        type: asset.type == AssetType.video ? 'video' : 'image',
        url: '',
      ),
    ];

    // Calculate itemCount (images only for provenance)
    final itemCount = items.where((it) => it.type != 'video' || it.videoUrl != null).length;
    final itemIndex = file.itemIndex;

    // Use savedAt from files_json as capturedAt (spec §7.2)
    final capturedAt = DateTime.fromMillisecondsSinceEpoch(file.savedAt);

    return ProvenanceBuilder(
      platform: record.platform,
      postId: record.postId,
      postUrl: record.postUrl,
      authorName: record.authorName,
      title: record.title,
      caption: record.caption,
      authorId: null, // Don't have authorId from history
      publishedAt: null, // Don't have from history
      itemIndex: itemIndex,
      itemCount: itemCount > 1 ? itemCount : 1,
      existingAssetId: file.assetId,
      capturedAt: capturedAt,
    ).build();
  }

  Future<void> _updateAssetId(
    HistoryRecord record,
    HistoryFile file,
    String assetId,
  ) async {
    // Update the assetId in the file
    final updatedFile = file.copyWith(assetId: assetId);
    final updatedFiles = record.files.map((f) =>
      f == file ? updatedFile : f
    ).toList();

    if (record.id != null) {
      final db = await HistoryDb.instance();
      await db.updateFiles(record.id!, updatedFiles);
    }
  }
}

enum _BackfillStatus {
  success,
  authRequired,
  fileNotFound,
  noWritePermission,
  formatNotSupported,
  otherError,
}

class _BackfillStatusResult {
  final _BackfillStatus status;

  _BackfillStatusResult(this.status);
}

class _BackfillItem {
  final AssetEntity asset;
  final String filePath;
  final HistoryRecord record;
  final HistoryFile file;

  _BackfillItem({
    required this.asset,
    required this.filePath,
    required this.record,
    required this.file,
  });
}
