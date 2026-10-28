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
import 'provenance_pair.dart';
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
      await locator.requestPermission(scan: false);
    }

    final settings = await AppSettings.load();
    final selectedAlbums = (albums == null)
        ? settings.effectiveAlbumNames
        : albums.toSet();

    final startedAt = DateTime.now();
    final assets = assetsOverride ??
        (includeAllAlbums
            ? await locator.allImages()
            : await locator.assetsInAlbums(selectedAlbums));
    final total = assets.length;
    if (assetsOverride == null && !locator.hasAccess && assets.isEmpty) throw Exception('没有相册访问权限，固定目录中也未找到可读取的媒体');

    DevLog.write(
      _logTag, // i18n:ignore 日志
      'scan start albums=${includeAllAlbums ? '<all>' : selectedAlbums.join(',')} '
      'fixedDirectory=$c2paRelativePath files=$total at=${startedAt.toIso8601String()}',
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
    final fileDiags = <String, _FileDiag>{};

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
        fileDiags[asset.id] = _FileDiag(
          filename: asset.title ?? asset.id,
          mime: mime,
          pairing: 'skipped',
          reason: 'unsupported MIME',
        );
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

      // Merge raw XMP so embedded user fields without prov:assetId survive.
      final provenance = mergeProvenanceXml(MetadataService.readXmpXmlFromBytes(bytes),
          await readProvenanceSidecarXml(asset.id));
      if (provenance != null &&
          provenance.platform != null &&
          provenance.sourceId != null) {
        final gKey = '${provenance.platform!}:${provenance.sourceId!}';
        fileDiags[asset.id] = _FileDiag(
          filename: asset.title ?? asset.id,
          mime: queryMime,
          sourceId: provenance.sourceId,
          itemIndex: provenance.itemIndex,
          pairId: provenance.pairId,
          groupKey: gKey,
          pairing: isVideo ? 'standalone_video' : 'standalone_image',
          reason: isVideo ? 'no matching image' : 'no candidate video',
        );
        if (isVideo) {
          identifiedVideos.add(_AssetWithXmp(asset, '', provenance));
        } else {
          identifiedImages.add(_AssetWithXmp(asset, '', provenance));
        }
      } else {
        fileDiags[asset.id] = _FileDiag(
          filename: asset.title ?? asset.id,
          mime: queryMime,
          pairing: isVideo ? 'unpaired_video' : 'skipped',
          reason: 'no XMP provenance',
        );
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
        if (sameIndexImages.length > 1) {
          fileDiags[img.asset.id]?.reason = 'multiple images share itemIndex $targetIndex';
          continue;
        }

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
            if (imgPair != vidPair) {
              fileDiags[vid.asset.id]?.reason = 'pairId mismatch ($vidPair != $imgPair)';
              continue;
            }
          }

          candidateVideos.add(vid);
        }

        // Pair only when exactly one candidate matches
        if (candidateVideos.length > 1) {
          fileDiags[img.asset.id]?.reason = 'multiple candidate videos (${candidateVideos.length})';
          for (final cv in candidateVideos) {
            fileDiags[cv.asset.id]?.reason = 'multiple candidate videos (${candidateVideos.length})';
          }
        } else if (candidateVideos.length == 1) {
          final matchedVid = candidateVideos.first;
          pairedVideoAssets.add(matchedVid.asset.id);
          pairedImageIds.add(img.asset.id);

          fileDiags[img.asset.id]?.pairing = 'paired_live_image';
          fileDiags[img.asset.id]?.reason = 'itemIndex match with ${matchedVid.asset.title ?? matchedVid.asset.id}';
          fileDiags[matchedVid.asset.id]?.pairing = 'paired_live_video';
          fileDiags[matchedVid.asset.id]?.reason = 'itemIndex match with ${img.asset.title ?? img.asset.id}';

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
      if (matchingCandidates.length > 1) {
        fileDiags[img.asset.id]?.reason = 'multiple fallback candidates (${matchingCandidates.length})';
      } else if (matchingCandidates.length == 1) {
        final vidAsset = matchingCandidates.first;
        pairedVideoAssets.add(vidAsset.id);
        pairedImageIds.add(img.asset.id);

        final key = '${img.provenance.platform!}:${img.provenance.sourceId!}';
        final vidProv = img.provenance.copyWith(itemIndex: img.provenance.itemIndex);

        fileDiags[img.asset.id]?.pairing = 'paired_live_image';
        fileDiags[img.asset.id]?.reason = 'fallback stem match with ${vidAsset.title ?? vidAsset.id}';
        final vidDiag = fileDiags[vidAsset.id];
        if (vidDiag != null) {
          vidDiag.groupKey = key;
          vidDiag.pairing = 'paired_live_video';
          vidDiag.reason = 'fallback stem match with ${img.asset.title ?? img.asset.id}';
        }

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

    // Log diagnostic line for each scanned file (SPEC / Requirement 5)
    for (final diag in fileDiags.values) {
      diag.log();
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
          relativePath: await locator.getRelativePath(awx.asset),
          status: FileStatus.found,
        ));
      }

      String generateItemsJson(List<HistoryFile> postFiles) {
        final byIndex = <int, List<HistoryFile>>{};
        for (final f in postFiles) {
          byIndex.putIfAbsent(f.itemIndex, () => []).add(f);
        }
        final sortedIndices = byIndex.keys.toList()..sort();
        final postItems = <Map<String, Object?>>[];
        for (final idx in sortedIndices) {
          final group = byIndex[idx]!;
          final img = group.where((f) => f.isImage).firstOrNull;
          final vid = group.where((f) => !f.isImage).firstOrNull;
          final isPaired = img != null &&
              vid != null &&
              img.mediaId != null &&
              vid.mediaId != null &&
              pairedImageIds.contains(img.mediaId) &&
              pairedVideoAssets.contains(vid.mediaId);
          if (img != null && vid != null && isPaired) {
            postItems.add({
              'type': 'live',
              'url': img.filename,
              'videoUrl': vid.filename,
            });
          } else {
            if (img != null) {
              postItems.add({
                'type': 'image',
                'url': img.filename,
              });
            }
            if (vid != null) {
              postItems.add({
                'type': 'video',
                'url': vid.filename,
                'videoUrl': vid.filename,
              });
            }
          }
        }
        return jsonEncode(postItems);
      }

      // Try to find existing record
      final db = dbOverride ?? await HistoryDb.instance();
      final existing = await db.getByPostId(sourceId);

      if (existing != null) {
        // Merge by mediaId: recognize existing files by mediaId, update itemIndex & pairing
        final scannedByMediaId = <String, HistoryFile>{
          for (final f in files)
            if (f.mediaId != null) f.mediaId!: f,
        };

        final mergedMap = <String, HistoryFile>{};

        for (final f in existing.files) {
          if (f.mediaId != null && scannedByMediaId.containsKey(f.mediaId)) {
            final rescanned = scannedByMediaId.remove(f.mediaId)!;
            final earliestSavedAt = rescanned.savedAt < f.savedAt ? rescanned.savedAt : f.savedAt;
            final key = '${rescanned.itemIndex}_${rescanned.isImage}';
            mergedMap[key] = HistoryFile(
              filename: rescanned.filename.isNotEmpty ? rescanned.filename : f.filename,
              savedAt: earliestSavedAt,
              mediaId: f.mediaId,
              itemIndex: rescanned.itemIndex,
              isImage: rescanned.isImage,
              assetId: rescanned.assetId ?? f.assetId,
              relativePath: rescanned.relativePath ?? f.relativePath,
              status: FileStatus.found,
            );
          } else {
            final key = '${f.itemIndex}_${f.isImage}';
            mergedMap[key] = f;
          }
        }

        for (final f in scannedByMediaId.values) {
          final key = '${f.itemIndex}_${f.isImage}';
          mergedMap[key] = f;
        }

        final mergedList = mergedMap.values.toList()
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
          aiLabel: existing.aiLabel ?? earliestAwx.provenance.aiLabel,
          aiLabelSource: existing.aiLabel != null ? existing.aiLabelSource : earliestAwx.provenance.aiLabelSource,
          thumbnailUrl: existing.thumbnailUrl,
          postUrl: existing.postUrl,
          fileCount: mergedList.length,
          createdAt: recordCreatedAt,
          itemsJson: generateItemsJson(mergedList),
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
          aiLabel: firstProv.aiLabel,
          aiLabelSource: firstProv.aiLabelSource,
          thumbnailUrl: null, // Will be populated by history page
          postUrl: firstProv.sourceUrl ?? 'https://unknown',
          fileCount: files.length,
          createdAt: recordCreatedAt,
          itemsJson: generateItemsJson(files),
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

class _FileDiag {
  final String filename;
  final String mime;
  final String? sourceId;
  final int? itemIndex;
  final String? pairId;
  String groupKey;
  String pairing;
  String reason;

  _FileDiag({
    required this.filename,
    required this.mime,
    this.sourceId,
    this.itemIndex,
    this.pairId,
    this.groupKey = 'none',
    this.pairing = 'none',
    this.reason = 'none',
  });

  void log() {
    DevLog.write(
      HistoryRebuildService._logTag,
      'file=$filename mime=$mime sourceId=${sourceId ?? "-"} '
      'itemIndex=${itemIndex ?? "-"} pairId=${pairId ?? "-"} '
      'group=$groupKey pairing=$pairing reason=$reason',
    );
  }
}

