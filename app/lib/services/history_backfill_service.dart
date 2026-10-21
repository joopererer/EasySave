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
  final int alreadyHasMetadata;
  final int fileNotFound;
  final int noWritePermission;
  final int formatNotSupported;
  final int otherError;

  const BackfillResult({
    required this.total,
    required this.success,
    required this.authRequired,
    required this.alreadyHasMetadata,
    required this.fileNotFound,
    required this.noWritePermission,
    required this.formatNotSupported,
    required this.otherError,
  });

  int get skipped => alreadyHasMetadata + fileNotFound + noWritePermission + formatNotSupported + otherError;

  @override
  String toString() {
    final parts = <String>[
      '$success/$total written',
      if (authRequired > 0) '$authRequired required permission',
      if (alreadyHasMetadata > 0) '$alreadyHasMetadata already had metadata',
      if (fileNotFound > 0) '$fileNotFound file not found',
      if (noWritePermission > 0) '$noWritePermission no write permission',
      if (formatNotSupported > 0) '$formatNotSupported format not supported',
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
  /// 1. Query HistoryDb for records with files having status == found
  /// 2. For each file with linked mediaId:
  ///    - Check if file already has XMP provenance (real check, not just assetId presence)
  ///    - If not: try to write metadata directly
  ///    - If not writable, request permission via MediaStore.createWriteRequest
  /// 3. Show result summary with breakdown by skip reason
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
    var alreadyHasMetadata = 0;
    var fileNotFound = 0;
    var noWritePermission = 0;
    var formatNotSupported = 0;
    var otherError = 0;

    // Collect all files needing backfill
    final filesToBackfill = <_BackfillItem>[];

    for (final record in recordsWithFiles) {
      for (final file in record.files) {
        if (file.status != FileStatus.found || file.mediaId == null) continue;

        // Try to get the file path
        final asset = GalleryLocatorService.instance.getAssetById(file.mediaId);
        if (asset == null) {
          fileNotFound++;
          DevLog.write(_logTag, 'Asset not found for ${file.filename}');
          continue;
        }

        File? filePath;
        try {
          filePath = await asset.file;
        } catch (_) {
          fileNotFound++;
          continue;
        }

        if (filePath == null || !await filePath.exists()) {
          fileNotFound++;
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
      total: total,
      success: success,
      authRequired: authRequired,
      alreadyHasMetadata: alreadyHasMetadata,
      fileNotFound: fileNotFound,
      noWritePermission: noWritePermission,
      formatNotSupported: formatNotSupported,
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
