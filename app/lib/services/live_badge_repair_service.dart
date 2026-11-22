import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import 'history_db.dart';
import 'live_pairs.dart';

/// One-time startup repair service for posts missing Live photo badges
/// or pairId markers on their saved file rows (v1.12.1 Item B).
class LiveBadgeRepairService {
  LiveBadgeRepairService._();

  static const String prefKey = 'live_badge_repaired_v1121';

  /// Runs the repair once if not already performed.
  /// Logs: `live_badge_repair posts=<n> pairs=<n>`.
  static Future<({int posts, int pairs})> repairIfNeeded({
    HistoryDb? db,
    SharedPreferences? prefs,
    bool force = false,
  }) async {
    final sp = prefs ?? await SharedPreferences.getInstance();
    if (!force && sp.getBool(prefKey) == true) {
      return (posts: 0, pairs: 0);
    }

    final database = db ?? await HistoryDb.instance();
    final records = await database.getAllActiveForBackup();
    var repairedPosts = 0;
    var repairedPairs = 0;

    for (final record in records) {
      final files = record.files;
      final entries = pairSavedMedia(files);
      final liveEntries = entries.where((e) => e.isLive).toList();
      if (liveEntries.isEmpty) continue;

      var postChanged = false;
      var postRepairedPairs = 0;
      final updatedFiles = List<HistoryFile>.from(files);

      for (final entry in liveEntries) {
        final pairId = '${record.postId}#${entry.itemIndex}';
        var pairFixed = false;
        if (entry.image != null && (entry.image!.pairId == null || entry.image!.pairId!.isEmpty)) {
          final idx = updatedFiles.indexOf(entry.image!);
          if (idx >= 0) {
            updatedFiles[idx] = entry.image!.copyWith(pairId: pairId);
            pairFixed = true;
          }
        }
        if (entry.video != null && (entry.video!.pairId == null || entry.video!.pairId!.isEmpty)) {
          final idx = updatedFiles.indexOf(entry.video!);
          if (idx >= 0) {
            updatedFiles[idx] = entry.video!.copyWith(pairId: pairId);
            pairFixed = true;
          }
        }
        if (pairFixed) {
          postRepairedPairs++;
          postChanged = true;
        }
      }

      // Check itemsJson to ensure matching items have type == 'live'
      String? updatedItemsJson = record.itemsJson;
      try {
        final post = record.toPost();
        var itemsChanged = false;
        final is1Based = record.visibleFiles.every((f) => f.itemIndex > 0);
        for (final entry in liveEntries) {
          final zeroBased = is1Based ? entry.itemIndex - 1 : entry.itemIndex;
          if (zeroBased >= 0 && zeroBased < post.items.length) {
            if (post.items[zeroBased].type != 'live') {
              final old = post.items[zeroBased];
              post.items[zeroBased] = MediaItem(
                type: 'live',
                url: old.url,
                videoUrl: old.videoUrl,
                posterUrl: old.posterUrl,
                thumbnailUrl: old.thumbnailUrl,
                width: old.width,
                height: old.height,
                duration: old.duration,
                isGif: old.isGif,
                fallbacks: old.fallbacks,
                requestResources: old.requestResources,
                localFilename: old.localFilename,
                localVideoFilename: old.localVideoFilename,
              );
              itemsChanged = true;
            }
          }
        }
        if (itemsChanged) {
          updatedItemsJson = jsonEncode(post.items.map((i) => i.toJson()).toList());
          postChanged = true;
        }
      } catch (_) {}

      if (postChanged) {
        final updatedRecord = HistoryRecord(
          platform: record.platform,
          postId: record.postId,
          authorName: record.authorName,
          title: record.title,
          caption: record.caption,
          aiLabel: record.aiLabel,
          aiLabelSource: record.aiLabelSource,
          thumbnailUrl: record.thumbnailUrl,
          postUrl: record.postUrl,
          fileCount: updatedFiles.where(isSavedHistoryFile).length,
          createdAt: record.createdAt,
          itemsJson: updatedItemsJson,
          files: updatedFiles,
          isDeleted: record.isDeleted,
          downloadError: record.downloadError,
          platformDisplayName: record.platformDisplayName,
        );
        await database.upsert(
          updatedRecord,
          restoreDeleted: true,
          userSave: false,
          source: 'live-badge-repair',
        );
        repairedPosts++;
        repairedPairs += postRepairedPairs > 0 ? postRepairedPairs : liveEntries.length;
      }
    }

    await sp.setBool(prefKey, true);
    DevLog.write('LiveBadgeRepair', 'live_badge_repair posts=$repairedPosts pairs=$repairedPairs');
    return (posts: repairedPosts, pairs: repairedPairs);
  }
}
