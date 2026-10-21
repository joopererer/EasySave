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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'history_db.dart';

class MediaDeleteService {
  MediaDeleteService._();

  static final MediaDeleteService instance = MediaDeleteService._();

  static const _channel = MethodChannel('easysave/media');

  /// Whether album-file deletion is available on this platform (Android only).
  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  /// Delete the given media from the album. Returns true when the user
  /// approved the system dialog and the files were removed, false when the
  /// dialog was declined or the OS/version cannot delete (caller keeps the
  /// records and informs the user).
  Future<bool> deleteMedia(List<MediaRef> media) async {
    final ids = <String>[];
    final isImage = <bool>[];
    for (final m in media) {
      if (m.mediaId.isEmpty) continue;
      ids.add(m.mediaId);
      isImage.add(m.isImage);
    }
    if (ids.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>('deleteMedia', {
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

  /// Request write access for media files through the OS confirmation flow.
  /// On Android 11+ (API 30+), apps can only modify media files they created.
  /// This method requests permission to write to existing files via
  /// `MediaStore.createWriteRequest`.
  ///
  /// Returns true if user grants permission, false otherwise.
  Future<bool> requestWriteAccess(List<MediaRef> media) async {
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
