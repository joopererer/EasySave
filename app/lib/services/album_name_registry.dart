// Copyright 2026 EasySave. All rights reserved.
//
// Keeps the list of albums the app has used up to date.
//
// The album names are never derived from file names (file names carry no
// album). They come from two sources:
//   * the album the user picked in the settings (remembered on rename), and
//   * MediaStore itself: for every file the history has located, the
//     BUCKET_DISPLAY_NAME / RELATIVE_PATH is queried.
//
// The second source is what fills the list on the first run, so a user who
// renamed the album (or who saved into several albums) still gets a complete
// list for the rebuild scan.

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:easysave/services/settings.dart';

abstract final class AlbumNameRegistry {
  static const String logTag = 'V16DL';

  /// How many located files are queried for their album. The album rarely
  /// changes between files, so a small sample is enough; the list is deduped
  /// anyway.
  static const int maxQueries = 20;

  /// Fill [settings].usedAlbumNames with the albums of the files the history
  /// has located. Returns the names that were added.
  static Future<List<String>> completeFromHistory(
    AppSettings settings, {
    HistoryDb? db,
    Future<({String? album, String? relativePath})?> Function(String mediaId)?
        queryAlbum,
  }) async {
    final store = db ?? await HistoryDb.instance();
    final records = await store.recent(limit: 200);

    final mediaIds = <String>[];
    final seen = <String>{};
    for (final record in records) {
      for (final file in record.files) {
        final id = file.mediaId;
        if (id == null || id.isEmpty) continue;
        if (!seen.add(id)) continue;
        mediaIds.add(id);
        if (mediaIds.length >= maxQueries) break;
      }
      if (mediaIds.length >= maxQueries) break;
    }

    final resolver = queryAlbum ?? MediaHeaderService.queryAlbum;
    final added = <String>[];
    for (final mediaId in mediaIds) {
      final info = await resolver(mediaId);
      final name = _albumNameOf(info?.album, info?.relativePath);
      if (name == null) continue;
      final before = settings.usedAlbumNames.length;
      settings.rememberAlbum(name);
      if (settings.usedAlbumNames.length > before) added.add(name);
    }

    if (added.isNotEmpty) {
      DevLog.write(
        logTag, // i18n:ignore 日志
        'album names completed from history: ${added.join(", ")} '
        '(total ${settings.effectiveAlbumNames.length})',
      );
    }
    return added;
  }

  /// The album name of a MediaStore row.
  ///
  /// RELATIVE_PATH looks like "EasySave/EasySave5/" — the first segment is
  /// the album folder, the rest is the (optional) sub folder. BUCKET_DISPLAY_NAME
  /// is the album name as the user sees it.
  static String? _albumNameOf(String? bucket, String? relativePath) {
    final fromBucket = bucket?.trim();
    if (fromBucket != null && fromBucket.isNotEmpty) return fromBucket;
    final path = relativePath?.trim();
    if (path == null || path.isEmpty) return null;
    final first = path.split('/').firstWhere(
          (segment) => segment.trim().isNotEmpty,
          orElse: () => '',
        );
    return first.isEmpty ? null : first;
  }
}
