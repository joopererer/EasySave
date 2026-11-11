// Frozen from 24fb900; only names/import paths adapted for the harness.
// Do not update expected behavior to match the migrated implementation.
import 'dart:convert';
import 'package:photo_manager/photo_manager.dart';
import 'package:easysave/core/app_version.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/download_manager.dart' show DownloadBatch;
import 'package:easysave/services/history_db.dart';
import 'url_normalizer_24fb900.dart';

XmpProvenance legacyBatchProvenance(
  DownloadBatch batch, {
  required int itemIndex,
  String? existingAssetId,
  String? capturedBy,
  String? pairId,
}) {
  final authorId = _shouldWriteAuthorId(batch.platform, batch.authorId)
      ? batch.authorId
      : null;
  return ProvenanceBuilder(
    platform: toSpecPlatform(batch.platform),
    capturedBy: capturedBy ?? AppVersion.capturedBy,
    sourceId: batch.postId,
    sourceUrl: batch.postUrl,
    authorName: batch.authorName,
    title: batch.title,
    caption: batch.caption,
    aiLabel: batch.aiLabel,
    aiLabelSource: batch.aiLabelSource,
    authorId: authorId,
    creditPlatformName: platformDisplayName(batch.platform),
    publishedAt: batch.publishedAt,
    itemIndex: itemIndex,
    itemCount: batch.totalItems,
    existingAssetId: existingAssetId,
  ).build().copyWith(pairId: pairId);
}

bool _shouldWriteAuthorId(String platform, String? authorId) {
  if (authorId == null || authorId.isEmpty) return false;
  if (platform != 'x' && platform != 'tiktok') return true;
  return RegExp(r'^\d+$').hasMatch(authorId);
}

XmpProvenance? legacyHistoryProvenance(
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
            .map(
              (raw) => MediaItem.fromJson((raw as Map).cast<String, dynamic>()),
            )
            .toList();
      }
    } catch (_) {}
  }

  // Fallback: create minimal item list
  items ??= [
    MediaItem(type: asset.type == AssetType.video ? 'video' : 'image', url: ''),
  ];

  // Calculate itemCount
  final itemCount = items
      .where((it) => it.type != 'video' || it.videoUrl != null)
      .length;
  final itemIndex = file.itemIndex;

  // Live Photo pairId check: only Live Photos write pairId
  final isLivePhoto =
      (items.length > itemIndex && items[itemIndex].videoUrl != null) ||
      (record.files.any((f) => f.itemIndex == itemIndex && f.isImage) &&
          record.files.any((f) => f.itemIndex == itemIndex && !f.isImage));
  final pairId = isLivePhoto ? '${record.postId}#$itemIndex' : null;

  // Use savedAt from files_json as capturedAt (spec §7.2)
  final capturedAt = DateTime.fromMillisecondsSinceEpoch(file.savedAt);

  return ProvenanceBuilder(
    platform: toSpecPlatform(record.platform),
    capturedBy: AppVersion.capturedBy,
    sourceId: record.postId,
    sourceUrl: record.postUrl,
    authorName: record.authorName,
    title: record.title,
    caption: record.caption,
    aiLabel: record.aiLabel,
    aiLabelSource: record.aiLabelSource,
    authorId: null, // Don't have authorId from history
    creditPlatformName: platformDisplayName(record.platform),
    publishedAt: null, // Don't have from history
    itemIndex: itemIndex,
    itemCount: itemCount > 1 ? itemCount : 1,
    existingAssetId: file.assetId,
    capturedAt: capturedAt,
  ).build().copyWith(pairId: pairId);
}
