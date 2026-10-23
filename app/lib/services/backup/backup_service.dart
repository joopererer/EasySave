// Copyright 2026 EasySave. All rights reserved.
// Core export, import, and reconciliation logic for backups (spec/backup.md).

import 'dart:async';
import 'dart:convert';

import '../../metadata/date_formatter.dart';
import '../../metadata/url_normalizer.dart';
import '../history_db.dart';
import '../settings.dart';
import 'backup_model.dart';

class ImportResult {
  final int restoredPosts;
  final int restoredFiles;
  final bool restoredSettings;
  final bool overlayNotice;
  final int insertedPosts;
  final int mergedPosts;
  final int skippedPosts;

  ImportResult({
    required this.restoredPosts,
    required this.restoredFiles,
    required this.restoredSettings,
    this.overlayNotice = false,
    this.insertedPosts = 0,
    this.mergedPosts = 0,
    this.skippedPosts = 0,
  });
}

abstract final class BackupService {
  /// Check if the active (non-deleted) history is empty.
  /// Shared across services and UI to enforce empty history protection.
  static Future<bool> isHistoryEmpty({HistoryDb? db}) async {
    final store = db ?? await HistoryDb.instance();
    final count = await store.countActive();
    return count == 0;
  }

  /// Export backup JSON containing active history records and non-sensitive settings.
  /// Strictly queries non-deleted records (`is_deleted = 0`).
  static Future<String> exportBackup({
    HistoryDb? db,
    AppSettings? settings,
    DateTime? now,
  }) async {
    final database = db ?? await HistoryDb.instance();
    final appSettings = settings ?? await AppSettings.load();
    final records = await database.getAllActiveForBackup();

    final backupPosts = <BackupPost>[];
    for (final record in records) {
      final specPlatform = toSpecPlatform(record.platform);

      // Structure items as a list of maps, not nested JSON strings
      List<Map<String, dynamic>>? structuredItems;
      if (record.itemsJson != null && record.itemsJson!.isNotEmpty) {
        try {
          final decoded = jsonDecode(record.itemsJson!);
          if (decoded is List) {
            structuredItems = [
              for (final it in decoded)
                if (it is Map) it.cast<String, dynamic>(),
            ];
          }
        } catch (_) {}
      }

      final backupFiles = <BackupFile>[];
      for (final f in record.files) {
        final savedDt = DateTime.fromMillisecondsSinceEpoch(f.savedAt);
        final savedAtStr = formatDateTimeWithTimezone(savedDt);
        final mediaType = f.isImage ? 'image' : 'video';

        Map<String, dynamic>? provenance;
        if (f.assetId != null && f.assetId!.isNotEmpty) {
          provenance = {
            'schema': '0.1',
            'assetId': f.assetId,
            'capturedAt': savedAtStr,
            'capturedBy': 'EasySave/${BackupData.currentAppVersion}',
            'metadataDate': savedAtStr,
            'source': {
              'url': normalizeUrl(record.postUrl),
              'platform': specPlatform,
              'id': record.postId,
              if (record.fileCount > 1) 'itemIndex': f.itemIndex,
              if (record.fileCount > 1) 'itemCount': record.fileCount,
            },
            if (record.title != null && record.title!.isNotEmpty)
              'title': record.title,
            if (record.authorName != null && record.authorName!.isNotEmpty)
              'creator': [record.authorName],
          };
        }

        backupFiles.add(
          BackupFile(
            filename: f.filename,
            relativePath: f.relativePath,
            savedAt: savedAtStr,
            mediaType: mediaType,
            mediaId: f.mediaId,
            itemIndex: f.itemIndex,
            assetId: f.assetId,
            provenance: provenance,
          ),
        );
      }

      final createdAtStr = formatDateTimeWithTimezone(record.createdAt);
      backupPosts.add(
        BackupPost(
          platform: specPlatform,
          sourceId: record.postId,
          originalUrl: record.postUrl,
          title: record.title,
          authorName: record.authorName,
          caption: record.caption,
          createdAt: createdAtStr,
          items: structuredItems,
          files: backupFiles,
        ),
      );
    }

    final backupSettings = BackupSettings(
      albumName: appSettings.albumName,
      usedAlbumNames: appSettings.usedAlbumNames,
      namePattern: appSettings.namePattern,
      saveProvenanceInImages: appSettings.saveProvenanceInImages,
      bubbleEnabled: appSettings.bubbleEnabled,
      bubbleAutoHide: appSettings.bubbleAutoHide,
      backgroundToast: appSettings.backgroundToast,
      autoClipboard: appSettings.autoClipboard,
      saveCaptionTxt: appSettings.saveCaptionTxt,
      historyView: appSettings.historyView.name,
      historyLayout: appSettings.historyLayout.name,
      historySort: appSettings.historySort.name,
    );

    final exportedAtStr = formatDateTimeWithTimezone(now ?? DateTime.now());
    final backupData = BackupData(
      exportedAt: exportedAtStr,
      settings: backupSettings,
      posts: backupPosts,
    );

    return const JsonEncoder.withIndent('  ').convert(backupData.toMap());
  }

  /// Parse backup metadata to display preview before restoring.
  static BackupPreview previewBackup(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('Root of backup is not a valid JSON object');
    }
    final data = BackupData.fromMap(decoded.cast<String, dynamic>());
    final totalFiles = data.posts.fold<int>(0, (sum, p) => sum + p.files.length);

    return BackupPreview(
      exportedAt: data.exportedAt,
      appVersion: data.appVersion,
      postCount: data.posts.length,
      fileCount: totalFiles,
      settings: data.settings,
      formatVersion: data.formatVersion,
    );
  }

  /// Import backup JSON and reconcile records into HistoryDb.
  /// Sets `restoreDeleted: true` so records that were valid in backup but deleted
  /// locally are restored.
  static Future<ImportResult> importBackup(
    String jsonStr, {
    HistoryDb? db,
    AppSettings? settings,
    bool restoreSettings = false,
    FutureOr<bool> Function(String)? checkOverlayPermission,
  }) async {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('Root of backup is not a valid JSON object');
    }
    final data = BackupData.fromMap(decoded.cast<String, dynamic>());
    final database = db ?? await HistoryDb.instance();

    var restoredFilesCount = 0;
    var insertedPosts = 0;
    var mergedPosts = 0;
    var skippedPosts = 0;

    for (final post in data.posts) {
      final appPlatform = toAppPlatform(post.platform);
      final existing = await database.getByPostId(post.sourceId) ??
          await database.getByPostUrl(post.originalUrl);
      if (existing == null) {
        insertedPosts++;
      } else {
        mergedPosts++;
      }

      final files = <HistoryFile>[];
      for (final f in post.files) {
        final isImage = f.mediaType != 'video';
        final savedAtMs =
            DateTime.tryParse(f.savedAt)?.millisecondsSinceEpoch ?? 0;
        files.add(
          HistoryFile(
            filename: f.filename,
            savedAt: savedAtMs,
            mediaId: f.mediaId,
            status: FileStatus.unknown,
            itemIndex: f.itemIndex,
            isImage: isImage,
            assetId: f.assetId,
            relativePath: f.relativePath,
          ),
        );
      }
      restoredFilesCount += files.length;

      String? itemsJson;
      if (post.items != null && post.items!.isNotEmpty) {
        itemsJson = jsonEncode(post.items);
      }

      DateTime? resolvedCreatedAt = DateTime.tryParse(post.createdAt);
      if (resolvedCreatedAt == null && files.isNotEmpty) {
        final validSavedAts = files.map((f) => f.savedAt).where((s) => s > 0).toList();
        if (validSavedAts.isNotEmpty) {
          validSavedAts.sort();
          resolvedCreatedAt = DateTime.fromMillisecondsSinceEpoch(validSavedAts.first);
        }
      }
      resolvedCreatedAt ??= DateTime.now();

      final record = HistoryRecord(
        platform: appPlatform,
        postId: post.sourceId,
        authorName: post.authorName,
        title: post.title,
        caption: post.caption,
        thumbnailUrl: null,
        postUrl: post.originalUrl,
        fileCount: files.length,
        createdAt: resolvedCreatedAt,
        itemsJson: itemsJson,
        files: files,
        isDeleted: false,
      );

      await database.upsert(record, restoreDeleted: true);
    }

    var overlayNotice = false;
    if (restoreSettings && settings != null) {
      settings.albumName = data.settings.albumName;
      settings.namePattern = data.settings.namePattern;
      settings.saveProvenanceInImages = data.settings.saveProvenanceInImages;
      settings.bubbleAutoHide = data.settings.bubbleAutoHide;
      settings.backgroundToast = data.settings.backgroundToast;
      settings.autoClipboard = data.settings.autoClipboard;
      settings.saveCaptionTxt = data.settings.saveCaptionTxt;
      settings.historyView = HistoryView.values.firstWhere(
        (v) => v.name == data.settings.historyView,
        orElse: () => HistoryView.posts,
      );
      settings.historyLayout = HistoryLayout.values.firstWhere(
        (v) => v.name == data.settings.historyLayout,
        orElse: () => HistoryLayout.waterfall,
      );
      settings.historySort = HistorySort.values.firstWhere(
        (v) => v.name == data.settings.historySort,
        orElse: () => HistorySort.latest,
      );

      // Union merge for usedAlbumNames:
      final mergedAlbums = <String>{
        ...settings.usedAlbumNames,
        ...data.settings.usedAlbumNames,
      };
      settings.usedAlbumNames = mergedAlbums.toList();

      // Bubble permission safeguard
      if (data.settings.bubbleEnabled) {
        final hasOverlay = checkOverlayPermission != null
            ? await checkOverlayPermission('overlay')
            : false;
        if (hasOverlay) {
          settings.bubbleEnabled = true;
        } else {
          settings.bubbleEnabled = false;
          overlayNotice = true;
        }
      } else {
        settings.bubbleEnabled = false;
      }

      await settings.save();
    }

    return ImportResult(
      restoredPosts: data.posts.length,
      restoredFiles: restoredFilesCount,
      restoredSettings: restoreSettings,
      overlayNotice: overlayNotice,
      insertedPosts: insertedPosts,
      mergedPosts: mergedPosts,
      skippedPosts: skippedPosts,
    );
  }
}
