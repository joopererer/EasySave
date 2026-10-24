// Copyright 2026 EasySave. All rights reserved.
// Service for rebuilding history from gallery scan.
// See spec/metadata.md §7.1

import 'dart:convert';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../metadata/metadata_service.dart';
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
    'video/mp4',
    'video/quicktime',
  };

  static String _fileStem(String filename) {
    final base = filename.split('/').last.split('\\').last;
    final dot = base.lastIndexOf('.');
    return (dot > 0 ? base.substring(0, dot) : base).toLowerCase();
  }

  static bool _isVideoAsset(AssetEntity asset) {
    if (asset.type == AssetType.video) return true;
    final mime = asset.mimeType?.toLowerCase();
    if (mime == 'video/mp4' || mime == 'video/quicktime') return true;
    final title = (asset.title ?? '').toLowerCase();
    return title.endsWith('.mp4') || title.endsWith('.mov');
  }

  static Future<bool> _isSameAlbum(AssetEntity a, AssetEntity b) async {
    final pathA = await GalleryLocatorService.instance.getRelativePath(a);
    final pathB = await GalleryLocatorService.instance.getRelativePath(b);
    if (pathA != null && pathB != null) {
      return GalleryLocatorService.normalizePath(pathA) ==
          GalleryLocatorService.normalizePath(pathB);
    }
    return pathA == pathB;
  }

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

    final identifiedImages = <_AssetWithXmp>[];
    final identifiedVideos = <_AssetWithXmp>[];
    final unidentifiedVideos = <AssetEntity>[];

    for (final asset in assets) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      processed++;
      onProgress?.call(processed, total, asset.title ?? 'unknown');

      final mime = asset.mimeType?.toLowerCase();
      final isVideo = _isVideoAsset(asset);

      // Only the formats the XMP readers understand are worth opening.
      if (mime != null && !supportedMimes.contains(mime)) {
        skipped++;
        continue;
      }

      final queryMime = mime ?? (isVideo ? 'video/mp4' : 'image/jpeg');

      // Read only the file header: the XMP lives there.
      Uint8List bytes = Uint8List(0);
      try {
        bytes = await reader(asset.id, queryMime);
      } catch (e) {
        DevLog.write(_logTag, 'Failed to read header of ${asset.title}: $e'); // i18n:ignore 日志
      }

      // Parse XMP from the header bytes.
      XmpProvenance? provenance;
      if (bytes.isNotEmpty) {
        try {
          provenance = MetadataService.readProvenanceFromBytes(bytes);
        } catch (e) {
          DevLog.write(_logTag, 'Failed to parse XMP of ${asset.title}: $e'); // i18n:ignore 日志
        }
      }

      if (provenance != null &&
          provenance.platform != null &&
          provenance.sourceId != null) {
        if (isVideo) {
          identifiedVideos.add(_AssetWithXmp(asset, '', provenance));
        } else {
          identifiedImages.add(_AssetWithXmp(asset, '', provenance));
        }
      } else {
        if (isVideo) {
          unidentifiedVideos.add(asset);
        } else {
          skipped++;
        }
      }
    }

    // Group assets by (platform, sourceId)
    final groups = <String, List<_AssetWithXmp>>{};
    final pairedVideoAssets = <String>{};
    final pairedImageIds = <String>{};

    // Add all identified images to their groups
    for (final img in identifiedImages) {
      final key = '${img.provenance.platform!}:${img.provenance.sourceId!}';
      groups.putIfAbsent(key, () => []).add(img);
    }

    // Index identified videos by (platform, sourceId)
    final identifiedVideosByGroup = <String, List<_AssetWithXmp>>{};
    for (final vid in identifiedVideos) {
      final key = '${vid.provenance.platform!}:${vid.provenance.sourceId!}';
      identifiedVideosByGroup.putIfAbsent(key, () => []).add(vid);
    }

    // 1. In each (platform, sourceId) group, pair by itemIndex
    // pairId is used only for cross-check (fail only when both have pairId and they differ)
    for (final entry in groups.entries) {
      final groupKey = entry.key;
      final groupImages = [...entry.value];
      final groupVideos = identifiedVideosByGroup[groupKey] ?? const [];

      for (final img in groupImages) {
        if (pairedImageIds.contains(img.asset.id)) continue;
        final targetIndex = img.provenance.itemIndex;
        if (targetIndex == null) continue;

        // If multiple images share the same itemIndex, do not pair
        final sameIndexImages = groupImages.where((i) => i.provenance.itemIndex == targetIndex).toList();
        if (sameIndexImages.length > 1) continue;

        // Find candidate videos in the same group with the same itemIndex
        final candidateVideos = <_AssetWithXmp>[];
        for (final vid in groupVideos) {
          if (pairedVideoAssets.contains(vid.asset.id)) continue;
          if (vid.provenance.itemIndex != targetIndex) continue;

          // Cross-check pairId: fail only when both have pairId and they differ
          final imgPair = img.provenance.pairId;
          final vidPair = vid.provenance.pairId;
          if (imgPair != null && imgPair.isNotEmpty &&
              vidPair != null && vidPair.isNotEmpty) {
            if (imgPair != vidPair) continue;
          }

          candidateVideos.add(vid);
        }

        // Pair only when exactly one candidate matches
        if (candidateVideos.length == 1) {
          final matchedVid = candidateVideos.first;
          pairedVideoAssets.add(matchedVid.asset.id);
          pairedImageIds.add(img.asset.id);

          final alignedVid = _AssetWithXmp(
            matchedVid.asset,
            matchedVid.path,
            matchedVid.provenance.copyWith(itemIndex: img.provenance.itemIndex),
          );
          entry.value.add(alignedVid);
        }
      }
    }

    // 2. Fallback pairing ONLY for unidentified videos (videos without XMP)
    for (final img in identifiedImages) {
      if (pairedImageIds.contains(img.asset.id)) continue;

      final imgStem = _fileStem(img.asset.title ?? '');
      if (imgStem.isEmpty) continue;

      final matchingCandidates = <AssetEntity>[];

      // Check unidentified videos only
      for (final vidAsset in unidentifiedVideos) {
        if (pairedVideoAssets.contains(vidAsset.id)) continue;
        if (_fileStem(vidAsset.title ?? '') != imgStem) continue;
        if (!await _isSameAlbum(img.asset, vidAsset)) continue;
        matchingCandidates.add(vidAsset);
      }

      // Pair only when exactly one candidate matches
      if (matchingCandidates.length == 1) {
        final vidAsset = matchingCandidates.first;
        pairedVideoAssets.add(vidAsset.id);
        pairedImageIds.add(img.asset.id);

        final key = '${img.provenance.platform!}:${img.provenance.sourceId!}';
        final vidProv = img.provenance.copyWith(itemIndex: img.provenance.itemIndex);

        final alignedVid = _AssetWithXmp(
          vidAsset,
          '',
          vidProv,
        );
        groups.putIfAbsent(key, () => []).add(alignedVid);
      }
    }

    // 3. Standalone identified videos (not paired with any image)
    for (final vid in identifiedVideos) {
      if (!pairedVideoAssets.contains(vid.asset.id)) {
        final key = '${vid.provenance.platform!}:${vid.provenance.sourceId!}';
        groups.putIfAbsent(key, () => []).add(vid);
      }
    }

    // Count skipped for unidentified videos that were not paired
    for (final vidAsset in unidentifiedVideos) {
      if (!pairedVideoAssets.contains(vidAsset.id)) {
        skipped++;
      }
    }

    // Process each group
    for (final entry in groups.entries) {
      final (platform, sourceId) = _parseKey(entry.key);
      final assetsWithXmp = entry.value;

      // SPEC §6: When the same item has multiple candidate assets (e.g. from different devices),
      // the asset with chronologically earlier capturedAt wins.
      final itemMap = <String, _AssetWithXmp>{};
      for (final awx in assetsWithXmp) {
        final itemIndex = awx.provenance.itemIndex ?? 1;
        final isImage = awx.asset.type == AssetType.image;
        final key = '${itemIndex}_$isImage';
        final existingItem = itemMap[key];
        if (existingItem == null) {
          itemMap[key] = awx;
        } else {
          final tExisting = existingItem.provenance.capturedAt ?? existingItem.asset.createDateTime;
          final tCurrent = awx.provenance.capturedAt ?? awx.asset.createDateTime;
          if (tCurrent.isBefore(tExisting)) {
            itemMap[key] = awx;
          }
        }
      }

      final resolvedAssets = itemMap.values.toList()
        ..sort((a, b) {
          final ai = a.provenance.itemIndex ?? 0;
          final bi = b.provenance.itemIndex ?? 0;
          return ai.compareTo(bi);
        });

      // Find the earliest captured asset across the group for the record header
      _AssetWithXmp earliestAwx = resolvedAssets.first;
      for (final awx in resolvedAssets.skip(1)) {
        final tEarliest = earliestAwx.provenance.capturedAt ?? earliestAwx.asset.createDateTime;
        final tCurrent = awx.provenance.capturedAt ?? awx.asset.createDateTime;
        if (tCurrent.isBefore(tEarliest)) {
          earliestAwx = awx;
        }
      }

      // Build history files
      final files = <HistoryFile>[];
      for (final awx in resolvedAssets) {
        final savedAtTime = awx.provenance.capturedAt ?? awx.asset.createDateTime;
        files.add(HistoryFile(
          filename: awx.asset.title ?? '',
          savedAt: savedAtTime.millisecondsSinceEpoch,
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
        final mergedFiles = <String, HistoryFile>{};
        for (final f in existing.files) {
          mergedFiles['${f.itemIndex}_${f.isImage}'] = f;
        }
        for (final f in files) {
          final key = '${f.itemIndex}_${f.isImage}';
          final existingF = mergedFiles[key];
          if (existingF == null || f.savedAt < existingF.savedAt) {
            mergedFiles[key] = f;
          }
        }

        final mergedList = mergedFiles.values.toList()
          ..sort((a, b) {
            final cmp = a.itemIndex.compareTo(b.itemIndex);
            if (cmp != 0) return cmp;
            return (a.isImage ? 0 : 1).compareTo(b.isImage ? 0 : 1);
          });

        final earliestTime = earliestAwx.provenance.capturedAt ?? earliestAwx.asset.createDateTime;
        final recordCreatedAt = earliestTime.isBefore(existing.createdAt) ? earliestTime : existing.createdAt;

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
          createdAt: recordCreatedAt,
          itemsJson: existing.itemsJson,
          files: mergedList,
        );

        await db.upsert(mergedRecord, restoreDeleted: true);
        merged++;
        DevLog.write(_logTag, 'Merged record: $platform:$sourceId'); // i18n:ignore 日志
      } else {
        final firstProv = earliestAwx.provenance;
        final recordCreatedAt = firstProv.capturedAt ?? earliestAwx.asset.createDateTime;
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

class _CandidateVideo {
  final AssetEntity asset;
  final XmpProvenance? provenance;

  _CandidateVideo(this.asset, this.provenance);
}
