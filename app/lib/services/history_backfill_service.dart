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
class BackfillResult {
  final int total;
  final int success;
  final int authRequired;
  final int skipped;

  const BackfillResult({
    required this.total,
    required this.success,
    required this.authRequired,
    required this.skipped,
  });

  @override
  String toString() =>
      '$success/$total written, $authRequired required permission, $skipped skipped';
}

/// Service for backfilling provenance metadata to old files.
class HistoryBackfillService {
  HistoryBackfillService._();

  static final HistoryBackfillService instance = HistoryBackfillService._();

  static const _logTag = 'HistoryBackfill';

  /// Backfill provenance metadata to files that don't have it.
  /// 
  /// Algorithm:
  /// 1. Query HistoryDb for records with files having status == found
  /// 2. For each file with linked mediaId:
  ///    - Try to write metadata directly
  ///    - If not writable, request permission via MediaStore.createWriteRequest
  /// 3. Show result summary
  Future<BackfillResult> backfill({
    void Function(int current, int total, String filename)? onProgress,
  }) async {
    final db = await HistoryDb.instance();
    final records = await db.recent(limit: 10000); // Get all records

    // Filter records with files that have mediaId (i.e., were successfully saved)
    final recordsWithFiles = records.where((r) =>
      r.files.any((f) => f.status == FileStatus.found && f.mediaId != null)
    ).toList();

    var total = 0;
    var success = 0;
    var authRequired = 0;
    var skipped = 0;

    // Collect all files needing backfill
    final filesToBackfill = <_BackfillItem>[];

    for (final record in recordsWithFiles) {
      for (final file in record.files) {
        if (file.status != FileStatus.found || file.mediaId == null) continue;

        // Skip if already has assetId (already has provenance)
        if (file.assetId != null) {
          skipped++;
          continue;
        }

        // Try to get the file path
        final asset = GalleryLocatorService.instance.getAssetById(file.mediaId);
        if (asset == null) {
          skipped++;
          continue;
        }

        File? filePath;
        try {
          filePath = await asset.file;
        } catch (_) {
          skipped++;
          continue;
        }

        if (filePath == null || !await filePath.exists()) {
          skipped++;
          continue;
        }

        // Check if file already has provenance metadata
        final existing = MetadataService.readProvenance(filePath.path);
        if (existing != null && existing.sourceUrl != null) {
          skipped++;
          continue;
        }

        total++;
        filesToBackfill.add(_BackfillItem(
          asset: asset,
          filePath: filePath.path,
          record: record,
          file: file,
        ));
      }
    }

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
        if (result == _BackfillStatus.success) {
          success++;
        } else if (result == _BackfillStatus.authRequired) {
          authRequired++;
        } else {
          skipped++;
        }
      }
    }

    return BackfillResult(
      total: total,
      success: success,
      authRequired: authRequired,
      skipped: skipped,
    );
  }

  Future<_BackfillStatus> _backfillFile(_BackfillItem item) async {
    final record = item.record;
    final file = item.file;
    final asset = item.asset;

    // Build provenance from history record
    final provenance = _buildProvenance(record, file, asset);
    if (provenance == null) {
      DevLog.write(_logTag, 'Failed to build provenance for ${asset.title}');
      return _BackfillStatus.skipped;
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
        return _BackfillStatus.success;
      }

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
            return _BackfillStatus.success;
          }
        }

        return _BackfillStatus.authRequired;
      }
    } catch (e) {
      DevLog.write(_logTag, 'Error writing provenance to ${asset.title}: $e');
    }

    return _BackfillStatus.skipped;
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
  skipped,
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
