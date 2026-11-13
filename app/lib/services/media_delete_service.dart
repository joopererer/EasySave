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
  String? get problem => !approved
      ? '相册文件未删除（已取消或系统不允许）'
      : remaining > 0
      ? '有 $remaining 个相册文件未能删除'
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
int savedFileCountFor(Iterable<HistoryRecord> records) => records.fold<int>(
  0,
  (sum, record) =>
      sum + record.files.where(isRetainedHistoryFile).length,
);

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
