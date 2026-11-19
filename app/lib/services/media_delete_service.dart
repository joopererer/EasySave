// Delete saved album files through the OS confirmation flow.
//
// Only files whose history status is [FileStatus.found] (i.e. we located a
// real MediaStore asset for them) are ever handed to the native layer. Files
// in [FileStatus.unknown] or [FileStatus.notFound] are not counted and not
// attempted, per the v1.5 delete spec.
//
// Platform: the Android side implements this with
// `MediaStore.createDeleteRequest` on API 30+. On API < 30 the call resolves
// to `false`; callers then fall back to deleting the history records only and
// tell the user the album files were kept. See MainActivity.kt for the full
// version breakdown.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'live_pairs.dart';

class MediaDeleteService {
  MediaDeleteService._();

  static final MediaDeleteService instance = MediaDeleteService._();

  static const _channel = MethodChannel('easysave/media');

  /// Whether album-file deletion is available on this platform (Android only).
  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  /// Delete the given media from the album.
  ///
  /// [MediaDeleteOutcome.approved] is false when the user declined the system
  /// dialog or the OS/version cannot delete. After an approval the album index
  /// is re-read so the caller can tell "deleted" from "approved but still
  /// there" — build 46 checked a box and lost nothing, and said so only in a
  /// generic message.
  Future<MediaDeleteOutcome> deleteMedia(List<MediaRef> media) async {
    final ids = <String>[];
    final isImage = <bool>[];
    for (final m in media) {
      if (m.mediaId.isEmpty) continue;
      ids.add(m.mediaId);
      isImage.add(m.isImage);
    }
    if (ids.isEmpty) {
      return const MediaDeleteOutcome(approved: false, requested: 0);
    }
    try {
      final result = await _channel.invokeMethod<bool>('deleteMedia', {
        'ids': ids,
        'isImage': isImage,
      });
      final approved = result ?? false;
      if (!approved) {
        return MediaDeleteOutcome(approved: false, requested: ids.length);
      }
      final locator = GalleryLocatorService.instance;
      locator.evictMediaIds(ids);
      var remaining = 0;
      try {
        await locator.scanAlbum(force: true).timeout(const Duration(seconds: 6));
        remaining = locator.remainingIds(ids).length;
      } catch (_) {
        // The index could not be re-read: report the approval, not a guess.
      }
      return MediaDeleteOutcome(
        approved: true,
        requested: ids.length,
        remaining: remaining,
      );
    } on PlatformException catch (e) {
      if (e.code == 'sidecar_delete_failed') {
        throw StateError('图片已删除，但来源边车删除失败，请检查 Download/EasySave');
      }
      return MediaDeleteOutcome(approved: false, requested: ids.length);
    } on MissingPluginException {
      return MediaDeleteOutcome(approved: false, requested: ids.length);
    }
  }

  /// Test override for requestWriteAccess.
  @visibleForTesting
  Future<bool> Function(List<MediaRef> media)? requestWriteAccessOverride;

  /// Request write access for media files through the OS confirmation flow.
  /// On Android 11+ (API 30+), apps can only modify media files they created.
  /// This method requests permission to write to existing files via
  /// `MediaStore.createWriteRequest`.
  ///
  /// Returns true if user grants permission, false otherwise.
  Future<bool> requestWriteAccess(List<MediaRef> media) async {
    final override = requestWriteAccessOverride;
    if (override != null) return override(media);

    if (!isSupported) return true; // iOS/non-Android has no restriction

    final ids = <String>[];
    final isImage = <bool>[];
    for (final m in media) {
      if (m.mediaId.isEmpty) continue;
      ids.add(m.mediaId);
      isImage.add(m.isImage);
    }
    if (ids.isEmpty) return false;

    try {
      final result = await _channel.invokeMethod<bool>('requestWriteAccess', {
        'ids': ids,
        'isImage': isImage,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// A locatable album asset to delete (id + collection type).
class MediaRef {
  const MediaRef({required this.mediaId, required this.isImage});

  final String mediaId;
  final bool isImage;
}

/// What actually happened to the album files of one delete request.
class MediaDeleteOutcome {
  const MediaDeleteOutcome({
    required this.approved,
    required this.requested,
    this.remaining = 0,
  });

  /// The OS dialog was approved (or the platform deleted without asking).
  final bool approved;

  /// How many files the request named.
  final int requested;

  /// How many of them the album still reports afterwards. 0 when the index
  /// could not be re-read, so a missing answer never looks like a failure.
  final int remaining;

  bool get deletedAll => approved && remaining == 0;

  /// Fixed, user-facing copy for the case where files stayed behind.
  ///
  /// No number: `remaining` counts files, and every user-visible number counts
  /// items (a Live photo's still and clip are one item), so a file number must
  /// never reach the screen (v1.11 build 59).
  String? get problem => !approved
      ? '相册文件未删除（已取消或系统不允许）'
      : remaining > 0
      ? '部分相册文件未能删除'
      : null;
}

/// Collect the deletable album files across [records]: only files that were
/// successfully located ([FileStatus.found]) with a real media id count.
List<MediaRef> deletableMediaFor(Iterable<HistoryRecord> records) {
  final media = <MediaRef>[];
  for (final record in records) {
    for (final file in record.files) {
      if (file.status != FileStatus.found) continue;
      final id = file.mediaId;
      if (id == null || id.isEmpty) continue;
      media.add(MediaRef(mediaId: id, isImage: file.isImage));
    }
  }
  return media;
}

/// How many files the selected posts actually saved.
///
/// The delete sheet must offer the real total: build 46 showed "1 个文件" for
/// two posts holding 3 + 4 files because it counted only the rows that already
/// carried a located album id. A row the album never confirmed still counts as
/// a file the user saved — it is just not one that can be deleted by id.
///
/// Files, not items: this is the count the album delete itself works with, and
/// it stays internal (logs and tests). Everything the user reads counts items —
/// see [savedItemCountFor] (v1.11 build 59).
int savedFileCountFor(Iterable<HistoryRecord> records) => records.fold<int>(
  0,
  (sum, record) =>
      sum + record.files.where(isRetainedHistoryFile).length,
);

/// How many items the selected posts actually saved.
///
/// A Live photo's still and motion clip are two files but one item, so every
/// user-visible number is this one (v1.11 build 59): the delete sheet's
/// 「同时删除相册中的 N 项」 and the result prompt after the system dialog.
int savedItemCountFor(Iterable<HistoryRecord> records) => records.fold<int>(
  0,
  (sum, record) =>
      sum + savedMediaEntryCount(record.files.where(isRetainedHistoryFile)),
);

/// How many items [media] covers across [records]: an item counts once even
/// when the request names both halves of a Live photo.
int deletableItemCountFor(
  Iterable<HistoryRecord> records,
  List<MediaRef> media,
) {
  final ids = {for (final ref in media) ref.mediaId};
  if (ids.isEmpty) return 0;
  var items = 0;
  for (final record in records) {
    for (final entry in pairSavedMedia(
      record.files.where(isRetainedHistoryFile),
    )) {
      if (entry.files.any((f) => f.mediaId != null && ids.contains(f.mediaId))) {
        items++;
      }
    }
  }
  return items;
}

/// Deletion item and file counts with unified format for Live and non-Live media.
class DeletionCounts {
  const DeletionCounts({
    required this.images,
    required this.videos,
    required this.livePhotos,
    this.other = 0,
    int? totalFilesOverride,
  }) : _totalFilesOverride = totalFilesOverride;

  final int images;
  final int videos;
  final int livePhotos;
  final int other;
  final int? _totalFilesOverride;

  int get totalItems => images + videos + livePhotos + other;
  int get totalFiles =>
      _totalFilesOverride ?? (images + videos + (livePhotos * 2) + other);

  /// Format string:
  /// - Live only: "3 个实况（共 6 个文件）"
  /// - Mixed: "2 张图片、3 个实况（共 8 个文件）", "1 个视频、3 个实况（共 7 个文件）"
  /// - Non-live: keep existing format (uses nonLiveFallback or default item/category count)
  String format({String? nonLiveFallback}) {
    if (livePhotos > 0) {
      final parts = <String>[];
      if (images > 0) parts.add('$images 张图片');
      if (videos > 0) parts.add('$videos 个视频');
      if (livePhotos > 0) parts.add('$livePhotos 个实况');
      if (other > 0) parts.add('$other 项');
      final desc = parts.join('、');
      return '$desc（共 $totalFiles 个文件）';
    }
    if (nonLiveFallback != null) return nonLiveFallback;
    final parts = <String>[];
    if (images > 0) parts.add('$images 张图片');
    if (videos > 0) parts.add('$videos 个视频');
    if (other > 0) parts.add('$other 项');
    return parts.isEmpty ? '$totalItems 项' : parts.join('、');
  }
}

DeletionCounts deletionCountsForRecords(Iterable<HistoryRecord> records) {
  var images = 0;
  var videos = 0;
  var livePhotos = 0;
  for (final record in records) {
    final entries = pairSavedMedia(record.savedFiles);
    for (final entry in entries) {
      if (entry.isLive) {
        livePhotos++;
      } else if (entry.image != null) {
        images++;
      } else if (entry.video != null) {
        videos++;
      }
    }
  }
  return DeletionCounts(
    images: images,
    videos: videos,
    livePhotos: livePhotos,
  );
}

DeletionCounts deletionCountsForGalleryItems(Iterable<dynamic> items) {
  var images = 0;
  var videos = 0;
  var livePhotos = 0;
  var other = 0;
  for (final item in items) {
    final type = (item as dynamic).type as String?;
    final hasLiveVideo = (item as dynamic).liveVideoAsset != null;
    if (type == 'live' || hasLiveVideo) {
      livePhotos++;
    } else if (type == 'video') {
      videos++;
    } else if (type == 'image' || type == 'gif') {
      images++;
    } else {
      other++;
    }
  }
  return DeletionCounts(
    images: images,
    videos: videos,
    livePhotos: livePhotos,
    other: other,
  );
}

/// The album files of [records] as they stand right now.
///
/// A history row only carries a media id once it was synced against the album,
/// so a post saved in this session (or one whose row was written by another
/// engine) can hold files that [deletableMediaFor] does not see yet. Refreshing
/// the index and the rows first is what makes "同时删除相册中的 N 个文件" true
/// instead of a checkbox that deletes nothing (build 46).
///
/// Read-only with respect to the album: it locates ids and writes history rows,
/// it never deletes anything.
Future<List<MediaRef>> resolveDeletableMedia(
  Iterable<HistoryRecord> records, {
  GalleryLocatorService? locator,
}) async {
  final service = locator ?? GalleryLocatorService.instance;
  try {
    await service.ensureIndexed();
  } catch (_) {
    // No album access: the caller reports that the files were kept.
  }
  for (final record in records) {
    try {
      await service.syncRecord(record);
    } catch (_) {
      // One unresolvable row must not stop the others.
    }
  }
  return deletableMediaFor(records);
}
