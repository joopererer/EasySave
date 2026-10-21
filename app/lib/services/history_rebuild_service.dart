// Copyright 2026 EasySave. All rights reserved.
// Service for rebuilding history from gallery scan.
// See spec/metadata.md §7.1

import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../metadata/metadata_service.dart';
import '../metadata/xmp_model.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';

/// Result of a rebuild operation.
class RebuildResult {
  final int total;
  final int processed;
  final int created;
  final int merged;
  final int skipped;

  const RebuildResult({
    required this.total,
    required this.processed,
    required this.created,
    required this.merged,
    required this.skipped,
  });

  @override
  String toString() =>
      '$processed/$total processed, $created new, $merged merged (including recovered), $skipped skipped';
}

/// Service for rebuilding history from gallery files.
class HistoryRebuildService {
  HistoryRebuildService._();

  static final HistoryRebuildService instance = HistoryRebuildService._();

  static const _logTag = 'HistoryRebuild';

  /// Rebuild history records from gallery files.
  /// Scans EasySave album, reads XMP from each file, and upserts to HistoryDb.
  Future<RebuildResult> rebuild({
    void Function(int current, int total, String filename)? onProgress,
  }) async {
    final locator = GalleryLocatorService.instance;

    // Check permission
    if (!locator.hasAccess) {
      await PhotoManager.requestPermissionExtend();
      if (!locator.hasAccess) {
        throw Exception('没有相册访问权限');
      }
    }

    // Scan album to get all assets
    await locator.scanAlbum(force: true);

    // Get all assets from locator
    final assets = locator.getScannedAssets();
    final total = assets.length;

    var processed = 0;
    var created = 0;
    var merged = 0;
    var skipped = 0;

    // Group assets by (platform, sourceId)
    final groups = <String, List<_AssetWithXmp>>{};

    for (final asset in assets) {
      processed++;
      onProgress?.call(processed, total, asset.title ?? 'unknown');

      File? path;
      try {
        path = await asset.file;
      } catch (_) {
        skipped++;
        continue;
      }
      if (path == null || !await path.exists()) {
        skipped++;
        continue;
      }

      // Read XMP from file
      XmpProvenance? provenance;
      try {
        provenance = MetadataService.readProvenance(path.path);
      } catch (e) {
        DevLog.write(_logTag, 'Failed to read XMP from ${asset.title}: $e');
        skipped++;
        continue;
      }

      if (provenance == null) {
        skipped++;
        continue;
      }

      // Check for required fields
      if (provenance.platform == null || provenance.sourceId == null) {
        skipped++;
        continue;
      }

      final key = '${provenance.platform!}:${provenance.sourceId!}';
      groups.putIfAbsent(key, () => []).add(_AssetWithXmp(asset, path.path, provenance));
    }

    // Process each group
    for (final entry in groups.entries) {
      final (platform, sourceId) = _parseKey(entry.key);
      final assetsWithXmp = entry.value;

      // Sort by itemIndex
      assetsWithXmp.sort((a, b) {
        final ai = a.provenance.itemIndex ?? 0;
        final bi = b.provenance.itemIndex ?? 0;
        return ai.compareTo(bi);
      });

      // Build history files
      final files = <HistoryFile>[];
      for (final awx in assetsWithXmp) {
        files.add(HistoryFile(
          filename: awx.asset.title ?? '',
          savedAt: awx.asset.createDateTime.millisecondsSinceEpoch,
          mediaId: awx.asset.id,
          itemIndex: awx.provenance.itemIndex ?? 1,
          isImage: awx.asset.type == AssetType.image,
          assetId: awx.provenance.assetId,
          status: FileStatus.found,
        ));
      }

      // Try to find existing record
      final db = await HistoryDb.instance();
      final existing = await db.getByPostId(sourceId);

      if (existing != null) {
        // Merge: update existing record with new file info
        final mergedFiles = <String, HistoryFile>{};
        for (final f in existing.files) {
          mergedFiles['${f.itemIndex}_${f.isImage}'] = f;
        }
        for (final f in files) {
          mergedFiles['${f.itemIndex}_${f.isImage}'] = f;
        }

        final mergedList = mergedFiles.values.toList()
          ..sort((a, b) {
            final cmp = a.itemIndex.compareTo(b.itemIndex);
            if (cmp != 0) return cmp;
            return (a.isImage ? 0 : 1).compareTo(b.isImage ? 0 : 1);
          });

        final mergedRecord = HistoryRecord(
          id: existing.id,
          platform: platform,
          postId: sourceId,
          authorName: existing.authorName,
          title: existing.title,
          caption: existing.caption,
          thumbnailUrl: existing.thumbnailUrl,
          postUrl: existing.postUrl,
          fileCount: mergedList.length,
          createdAt: existing.createdAt,
          itemsJson: existing.itemsJson,
          files: mergedList,
        );

        await db.upsert(mergedRecord, restoreDeleted: true);
        merged++;
        DevLog.write(_logTag, 'Merged record: $platform:$sourceId');
      } else {
        // Create new record
        final firstProv = assetsWithXmp.first.provenance;
        final record = HistoryRecord(
          platform: platform,
          postId: sourceId,
          authorName: firstProv.creators?.firstOrNull,
          title: firstProv.title,
          caption: firstProv.description,
          thumbnailUrl: null, // Will be populated by history page
          postUrl: firstProv.sourceUrl ?? 'https://unknown',
          fileCount: files.length,
          createdAt: DateTime.now(),
          files: files,
        );

        await db.upsert(record, restoreDeleted: true);
        created++;
        DevLog.write(_logTag, 'Created record: $platform:$sourceId');
      }
    }

    return RebuildResult(
      total: total,
      processed: processed,
      created: created,
      merged: merged,
      skipped: skipped,
    );
  }

  (String platform, String sourceId) _parseKey(String key) {
    final colon = key.indexOf(':');
    if (colon < 0) return ('unknown', key);
    return (key.substring(0, colon), key.substring(colon + 1));
  }
}

class _AssetWithXmp {
  final AssetEntity asset;
  final String path;
  final XmpProvenance provenance;

  _AssetWithXmp(this.asset, this.path, this.provenance);
}
