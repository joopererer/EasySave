// Copyright 2026 EasySave. All rights reserved.
// Service for rebuilding history from gallery scan.
// See spec/metadata.md §7.1

import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../metadata/metadata_service.dart';
import '../metadata/xmp_model.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'media_header_service.dart';
import 'settings.dart';

/// Result of a rebuild operation.
class RebuildResult {
  final int total;
  final int processed;
  final int created;
  final int merged;
  final int skipped;

  /// True when the user cancelled: everything processed up to that point was
  /// still written, only the remaining files were not scanned.
  final bool cancelled;

  const RebuildResult({
    required this.total,
    required this.processed,
    required this.created,
    required this.merged,
    required this.skipped,
    this.cancelled = false,
  });

  @override
  String toString() =>
      '$processed/$total processed, $created new, $merged merged (including recovered), $skipped skipped'
      '${cancelled ? ' (cancelled)' : ''}';
}

/// Service for rebuilding history from gallery files.
class HistoryRebuildService {
  HistoryRebuildService._();

  static final HistoryRebuildService instance = HistoryRebuildService._();

  static const _logTag = 'HistoryRebuild';

  /// The only formats whose XMP the rebuild scan can understand.
  static const Set<String> supportedMimes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  /// Rebuild history records from gallery files.
  ///
  /// Reads the provenance metadata of each file in [albums] (the used albums
  /// by default) and upserts one history record per post. Only the file
  /// headers are fetched (see [MediaHeaderService]), so a rebuild no longer
  /// copies every file out of the album.
  ///
  /// [onProgress] reports "已扫描 n / N"; [isCancelled] is polled before each
  /// file, and cancelling keeps everything processed so far.
  Future<RebuildResult> rebuild({
    Set<String>? albums,
    bool includeAllAlbums = false,
    void Function(int current, int total, String filename)? onProgress,
    bool Function()? isCancelled,
    Future<Uint8List> Function(String mediaId, String? mimeType)? readHeader,
    List<AssetEntity>? assetsOverride,
    HistoryDb? dbOverride,
  }) async {
    final locator = GalleryLocatorService.instance;

    // Check permission (only needed when the album really has to be read).
    if (assetsOverride == null && !locator.hasAccess) {
      await PhotoManager.requestPermissionExtend();
      if (!locator.hasAccess) {
        throw Exception('没有相册访问权限');
      }
    }

    final settings = await AppSettings.load();
    final selectedAlbums = (albums == null || albums.isEmpty)
        ? settings.effectiveAlbumNames
        : albums.toSet();

    final startedAt = DateTime.now();
    final assets = assetsOverride ??
        (includeAllAlbums
            ? await locator.allImages()
            : await locator.assetsInAlbums(selectedAlbums));
    final total = assets.length;

    DevLog.write(
      _logTag, // i18n:ignore 日志
      'scan start albums=${includeAllAlbums ? '<all>' : selectedAlbums.join(',')} '
      'files=$total at=${startedAt.toIso8601String()}',
    );

    final reader = readHeader ?? MediaHeaderService.readHeader;

    var processed = 0;
    var created = 0;
    var merged = 0;
    var skipped = 0;
    var cancelled = false;

    // Group assets by (platform, sourceId)
    final groups = <String, List<_AssetWithXmp>>{};

    for (final asset in assets) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      processed++;
      onProgress?.call(processed, total, asset.title ?? 'unknown');

      // Only the formats the XMP readers understand are worth opening.
      final mime = asset.mimeType?.toLowerCase();
      if (mime == null || !supportedMimes.contains(mime)) {
        skipped++;
        continue;
      }

      // Read only the file header: the XMP lives there, and copying the
      // whole file out of the album was what made a rebuild slow.
      Uint8List bytes;
      try {
        bytes = await reader(asset.id, mime);
      } catch (e) {
        DevLog.write(_logTag, 'Failed to read header of ${asset.title}: $e'); // i18n:ignore 日志
        skipped++;
        continue;
      }
      if (bytes.isEmpty) {
        skipped++;
        continue;
      }

      // Parse XMP from the header bytes.
      XmpProvenance? provenance;
      try {
        provenance = MetadataService.readProvenanceFromBytes(bytes);
      } catch (e) {
        DevLog.write(_logTag, 'Failed to parse XMP of ${asset.title}: $e'); // i18n:ignore 日志
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
      groups.putIfAbsent(key, () => []).add(_AssetWithXmp(asset, '', provenance));
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
      final db = dbOverride ?? await HistoryDb.instance();
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
        DevLog.write(_logTag, 'Merged record: $platform:$sourceId'); // i18n:ignore 日志
      } else {
        final firstAwx = assetsWithXmp.first;
        final firstProv = firstAwx.provenance;
        final recordCreatedAt = firstProv.capturedAt ?? firstAwx.asset.createDateTime;
        final record = HistoryRecord(
          platform: platform,
          postId: sourceId,
          authorName: firstProv.creators?.firstOrNull,
          title: firstProv.title,
          caption: firstProv.description,
          thumbnailUrl: null, // Will be populated by history page
          postUrl: firstProv.sourceUrl ?? 'https://unknown',
          fileCount: files.length,
          createdAt: recordCreatedAt,
          files: files,
        );

        await db.upsert(record, restoreDeleted: true);
        created++;
        DevLog.write(_logTag, 'Created record: $platform:$sourceId'); // i18n:ignore 日志
      }
    }

    final finishedAt = DateTime.now();
    final elapsed = finishedAt.difference(startedAt).inMilliseconds;
    DevLog.write(
      _logTag, // i18n:ignore 日志
      'scan end files=$total processed=$processed created=$created '
      'merged=$merged skipped=$skipped cancelled=$cancelled '
      'elapsedMs=$elapsed at=${finishedAt.toIso8601String()}',
    );

    return RebuildResult(
      total: total,
      processed: processed,
      created: created,
      merged: merged,
      skipped: skipped,
      cancelled: cancelled,
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
