// Copyright 2026 EasySave. All rights reserved.
// Core export, import, and reconciliation logic for backups (spec/backup.md).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:provenance_dart/provenance_dart.dart';

import '../../core/dev_log.dart';
import '../../metadata/url_normalizer.dart';
import '../history_db.dart';
import '../image_format_preference.dart';
import '../live_pairs.dart';
import '../settings.dart';
import 'backup_model.dart';
import 'backup_restore_matcher.dart';

class ImportResult {
  final int restoredPosts;

  /// Files the restore brought back. Internal: every user-visible number is
  /// [restoredItems] (a Live photo's still and clip are one item).
  final int restoredFiles;

  /// Items the restore brought back (v1.11 build 59).
  final int restoredItems;
  final bool restoredSettings;
  final bool overlayNotice;
  final int insertedPosts;
  final int mergedPosts;
  final int skippedPosts;

  /// Backup files with no matching album file on this device.
  final int notOnDevice;

  /// Items among [notOnDevice]; this is what the summary shows.
  final int notOnDeviceItems;

  ImportResult({
    required this.restoredPosts,
    required this.restoredFiles,
    int? restoredItems,
    required this.restoredSettings,
    this.overlayNotice = false,
    this.insertedPosts = 0,
    this.mergedPosts = 0,
    this.skippedPosts = 0,
    this.notOnDevice = 0,
    int? notOnDeviceItems,
  }) : restoredItems = restoredItems ?? restoredFiles,
       notOnDeviceItems = notOnDeviceItems ?? notOnDevice;
}

abstract final class BackupService {
  /// Check if the active (non-deleted) history is empty.
  /// Shared across services and UI to enforce empty history protection.
  static Future<bool> isHistoryEmpty({HistoryDb? db}) async {
    final store = db ?? await HistoryDb.instance();
    final count = await store.countActive();
    return count == 0;
  }

  /// MediaStore sizes by id for files recorded before sizes were stored.
  @visibleForTesting
  static Future<Map<String, int>> Function(List<String> ids)? mediaSizesReader;

  static Future<Map<String, int>> _mediaSizes(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final reader = mediaSizesReader;
    if (reader != null) return reader(ids);
    try {
      final raw = await const MethodChannel('easysave/media')
          .invokeMapMethod<String, num>('mediaSizes', {'ids': ids});
      return {for (final e in (raw ?? const {}).entries) e.key: e.value.toInt()};
    } catch (_) {
      return const {};
    }
  }

  /// Files worth backing up: located files, files with a physical identity
  /// (mediaId / assetId) including ones missing on this device, and every item
  /// the user deleted in the app — that last one carries no album identity any
  /// more, but the state itself is what a restore must keep.
  static bool _exportable(HistoryFile f) =>
      f.status == FileStatus.found ||
      f.status == FileStatus.deleted ||
      f.mediaId?.trim().isNotEmpty == true ||
      f.assetId?.trim().isNotEmpty == true;

  /// The on-device state written into a backup file (v1.11 batch 4).
  static BackupFileStatus backupStatusOf(HistoryFile file) => switch (file.status) {
    FileStatus.found => BackupFileStatus.inDevice,
    FileStatus.notFound => BackupFileStatus.missing,
    FileStatus.deleted => BackupFileStatus.deleted,
    FileStatus.unknown => BackupFileStatus.unknown,
  };

  static BackupPostStatus statusOf(HistoryRecord record) {
    // Judged by the stored rows, not by the rows confirmed in the album: a file
    // this device cannot locate is still part of the post and is exported as an
    // identity the restoring device may verify. An item the user deleted is not
    // part of the post any more, so it does not make the post "saved" either.
    if (record.visibleFiles.isEmpty) return BackupPostStatus.failed;
    return record.downloadError != null
        ? BackupPostStatus.partial
        : BackupPostStatus.success;
  }

  /// Canonical post URL under the current spec, or null when it would carry a
  /// query (only originalUrl may).
  static String? _canonicalOf(String url) {
    final canonical = canonicalForComparison(url);
    final uri = Uri.tryParse(canonical);
    if (uri == null || !uri.hasScheme || uri.hasQuery || uri.hasFragment) return null;
    return canonical;
  }

  /// Export a schema v2 backup of active history and non-sensitive settings.
  /// Strictly queries non-deleted records (`is_deleted = 0`). No media,
  /// thumbnail or cover URL is written; only originalUrl may carry a query.
  static Future<String> exportBackup({
    HistoryDb? db,
    AppSettings? settings,
    DateTime? now,
  }) async {
    final database = db ?? await HistoryDb.instance();
    final appSettings = settings ?? await AppSettings.load();
    final records = await database.getAllActiveForBackup();
    final sizes = await _mediaSizes([
      for (final record in records)
        for (final f in record.files)
          if (_exportable(f) && f.size == null && f.mediaId?.isNotEmpty == true)
            f.mediaId!,
    ]);

    final backupPosts = <BackupPost>[];
    for (final record in records) {
      final status = statusOf(record);
      final files = [
        for (final f in record.files.where(_exportable))
          BackupFile(
            itemIndex: f.itemIndex,
            mediaType: f.isImage ? 'image' : 'video',
            filename: f.filename,
            relativePath: f.relativePath,
            size: f.size ?? sizes[f.mediaId],
            assetId: f.assetId,
            mediaIdHint: f.mediaId,
            savedAt: formatDateTimeWithTimezone(
              DateTime.fromMillisecondsSinceEpoch(f.savedAt),
            ),
            itemCount: f.itemCount,
            capturedBy: f.capturedBy,
            status: backupStatusOf(f),
          ),
      ];
      backupPosts.add(
        BackupPost(
          platform: toSpecPlatform(record.platform),
          sourceId: record.postId,
          canonicalUrl: _canonicalOf(record.postUrl),
          originalUrl: record.postUrl,
          title: record.title,
          authorName: record.authorName,
          caption: record.caption,
          aiLabel: record.aiLabel,
          aiLabelSource: record.aiLabelSource,
          savedAt: formatDateTimeWithTimezone(record.createdAt),
          status: status,
          failureReason: status == BackupPostStatus.success ||
                  record.downloadError?.isEmpty != false
              ? null
              : record.downloadError,
          files: files,
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
      bubblePreviewSticky: appSettings.bubblePreviewSticky,
      backgroundToast: appSettings.backgroundToast,
      autoClipboard: appSettings.autoClipboard,
      saveCaptionTxt: appSettings.saveCaptionTxt,
      historyView: appSettings.historyView.name,
      historyLayout: appSettings.historyLayout.name,
      historySort: appSettings.historySort.name,
      imageFormat: appSettings.imageFormat.name,
      autoFolderBackupEnabled: appSettings.autoFolderBackupEnabled,
      autoBackupFolderName: appSettings.backupFolderName,
    );

    final exportedAtStr = formatDateTimeWithTimezone(now ?? DateTime.now());
    final backupData = BackupData(
      exportedAt: exportedAtStr,
      settings: backupSettings,
      posts: backupPosts,
    );

    final json = const JsonEncoder.withIndent('  ').convert(backupData.toMap());
    unawaited(DevLog.write('Backup', 'event=export schema=${BackupData.currentSchemaVersion} '
        'posts=${backupPosts.length} files=${backupPosts.fold<int>(0, (n, p) => n + p.files.length)} '
        'bytes=${utf8.encode(json).length}'));
    return json;
  }

  /// Parse backup metadata to display preview before restoring.
  static BackupPreview previewBackup(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('Root of backup is not a valid JSON object');
    }
    final data = BackupData.fromMap(decoded.cast<String, dynamic>());
    // An item the user deleted is not a file a restore will bring back, so it
    // is not part of the "N 项" the preview promises (v1.11 batch 4). The
    // preview counts items, never files (v1.11 build 59): a Live photo's still
    // and clip are one item.
    final files = [
      for (final p in data.posts)
        for (final f in p.files)
          if (!f.status.isDeleted) f,
    ];
    final totalFiles = files.length;
    final totalItems = savedMediaEntryCount([
      for (final f in files)
        HistoryFile(
          filename: f.filename,
          savedAt: DateTime.tryParse(f.savedAt)?.millisecondsSinceEpoch ?? 0,
          itemIndex: f.itemIndex,
          isImage: f.mediaType != 'video',
        ),
    ]);

    return BackupPreview(
      exportedAt: data.exportedAt,
      appVersion: data.appVersion,
      postCount: data.posts.length,
      fileCount: totalFiles,
      itemCount: totalItems,
      settings: data.settings,
      formatVersion: data.formatVersion,
    );
  }

  /// Import a v1 or v2 backup and reconcile it into HistoryDb.
  ///
  /// Each backup file is linked to an album file only through
  /// [BackupRestoreMatcher] (provenance, then name convention, then a verified
  /// mediaId hint); unmatched files are recorded as not on this device. Files
  /// this device already located are kept. Failed and partial posts keep their
  /// status so history offers a retry. Records deleted locally but valid in
  /// the backup are restored (`restoreDeleted: true`). Restoring the same
  /// backup twice gives the same history.
  static Future<ImportResult> importBackup(
    String jsonStr, {
    HistoryDb? db,
    AppSettings? settings,
    bool restoreSettings = false,
    FutureOr<bool> Function(String)? checkOverlayPermission,
    RestoreAlbum? album,
    void Function(int done, int total)? onProgress,
  }) async {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      throw const FormatException('Root of backup is not a valid JSON object');
    }
    final data = BackupData.fromMap(decoded.cast<String, dynamic>());
    final database = db ?? await HistoryDb.instance();
    final matcher = BackupRestoreMatcher(album ?? LocatorRestoreAlbum());
    final indexed = await matcher.prepare();

    var restoredFilesCount = 0;
    var restoredItemsCount = 0;
    var notOnDeviceItemsCount = 0;
    var insertedPosts = 0;
    var mergedPosts = 0;
    var skippedPosts = 0;
    final via = <RestoreMatchVia, int>{};
    var notOnDevice = 0;
    final total = data.posts.length;
    var done = 0;
    onProgress?.call(0, total);

    for (final post in data.posts) {
      if (done > 0) onProgress?.call(done, total);
      done++;
      final appPlatform = toAppPlatform(post.platform);
      final postUrl = post.originalUrl.trim().isNotEmpty
          ? post.originalUrl
          : (post.canonicalUrl ?? '');
      if (post.sourceId.trim().isEmpty || postUrl.trim().isEmpty) {
        skippedPosts++;
        continue;
      }
      final existing =
          await database.getByPostId(post.sourceId, platform: appPlatform) ??
              await database.getByPostUrl(postUrl);
      if (existing == null) {
        insertedPosts++;
      } else {
        mergedPosts++;
      }

      // Files this device already located stay as they are, and so does an item
      // the user deleted here: a restore must not bring it back (v1.11 batch 4).
      final localRows = existing?.files ?? const <HistoryFile>[];
      final located = <String, HistoryFile>{
        for (final f in localRows)
          if (f.status == FileStatus.deleted ||
              (f.status == FileStatus.found && f.mediaId?.isNotEmpty == true))
            '${f.itemIndex}_${f.isImage}': f,
      };
      for (final f in localRows) {
        if (f.status != FileStatus.found) continue;
        matcher.reserve(f.mediaId);
      }

      final files = <HistoryFile>[];
      final ordered = [...post.files]..sort((a, b) => a.itemIndex.compareTo(b.itemIndex));
      for (final f in ordered) {
        final isImage = f.mediaType != 'video';
        // An item the user deleted in the app comes back as deleted: it is not
        // missing, so it is never matched against the album and never offered
        // for a re-download (v1.11 batch 4).
        if (f.status.isDeleted) {
          files.add(
            HistoryFile(
              filename: f.filename,
              savedAt: DateTime.tryParse(f.savedAt)?.millisecondsSinceEpoch ?? 0,
              mediaId: f.mediaIdHint,
              status: FileStatus.deleted,
              itemIndex: f.itemIndex,
              isImage: isImage,
              assetId: f.assetId,
              relativePath: f.relativePath,
              itemCount: f.itemCount,
              capturedBy: f.capturedBy,
              size: f.size,
            ),
          );
          continue;
        }
        final known = located['${f.itemIndex}_$isImage'];
        if (known != null) {
          files.add(known);
          continue;
        }
        final match = await matcher.match(post, f);
        if (match != null) {
          via[match.via] = (via[match.via] ?? 0) + 1;
        } else if (indexed) {
          notOnDevice++;
        }
        files.add(
          HistoryFile(
            filename: match?.asset.title ?? f.filename,
            savedAt: DateTime.tryParse(f.savedAt)?.millisecondsSinceEpoch ?? 0,
            mediaId: match?.asset.id,
            status: match != null
                ? FileStatus.found
                : (indexed ? FileStatus.notFound : FileStatus.unknown),
            itemIndex: f.itemIndex,
            isImage: isImage,
            assetId: f.assetId,
            relativePath: match?.asset.relativePath ?? f.relativePath,
            itemCount: f.itemCount,
            capturedBy: f.capturedBy,
            size: f.size,
          ),
        );
      }
      final filesWithPairs = ensureLivePairIds(post.sourceId, files);
      final restoredFiles = repairHistoryFiles(filesWithPairs) ?? filesWithPairs;
      restoredFilesCount += restoredFiles.where(isVisibleHistoryFile).length;
      // Items, not files, for everything the user reads (v1.11 build 59).
      restoredItemsCount += savedMediaEntryCount(
        restoredFiles.where(isVisibleHistoryFile),
      );
      notOnDeviceItemsCount += savedMediaEntryCount(
        restoredFiles.where(isMissingHistoryFile),
      );

      DateTime? resolvedCreatedAt = DateTime.tryParse(post.savedAt);
      if (resolvedCreatedAt == null && files.isNotEmpty) {
        final validSavedAts = files.map((f) => f.savedAt).where((s) => s > 0).toList();
        if (validSavedAts.isNotEmpty) {
          validSavedAts.sort();
          resolvedCreatedAt = DateTime.fromMillisecondsSinceEpoch(validSavedAts.first);
        }
      }
      resolvedCreatedAt ??= DateTime.now();

      // Failed and partial posts stay retryable. A post this device already
      // saved files for keeps its own state over an older failure.
      final String? downloadError = switch (post.status) {
        BackupPostStatus.success => null,
        BackupPostStatus.partial => post.failureReason ?? '',
        BackupPostStatus.failed => existing?.savedFiles.isNotEmpty == true
            ? existing!.downloadError
            : post.failureReason ?? '',
      };

      final record = HistoryRecord(
        platform: appPlatform,
        postId: post.sourceId,
        authorName: post.authorName,
        title: post.title,
        caption: post.caption,
        aiLabel: post.aiLabel,
        aiLabelSource: post.aiLabelSource,
        thumbnailUrl: null,
        postUrl: existing?.postUrl ?? postUrl,
        fileCount: restoredFiles.where(isSavedHistoryFile).length,
        createdAt: resolvedCreatedAt,
        // Media URLs are not backed up; a local record keeps its own items.
        itemsJson: existing?.itemsJson,
        files: restoredFiles,
        isDeleted: false,
        downloadError: downloadError,
      );

      await database.upsert(record, restoreDeleted: true, source: 'backup-restore');
    }
    onProgress?.call(total, total);
    unawaited(DevLog.write('BackupRestore', 'event=done schema=${data.schemaVersion} '
        'posts=${data.posts.length} inserted=$insertedPosts merged=$mergedPosts '
        'skipped=$skippedPosts files=$restoredFilesCount indexed=${indexed ? 1 : 0} '
        'viaProvenance=${via[RestoreMatchVia.provenance] ?? 0} '
        'viaFilename=${via[RestoreMatchVia.filename] ?? 0} '
        'viaMediaIdHint=${via[RestoreMatchVia.mediaIdHint] ?? 0} '
        'notOnDevice=$notOnDevice'));

    var overlayNotice = false;
    if (restoreSettings && settings != null) {
      settings.albumName = data.settings.albumName;
      settings.namePattern = data.settings.namePattern;
      settings.saveProvenanceInImages = data.settings.saveProvenanceInImages;
      settings.bubbleAutoHide = data.settings.bubbleAutoHide;
      settings.bubblePreviewSticky = data.settings.bubblePreviewSticky;
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
      // v1.11 batch 3: 图片格式. A backup written before the setting existed
      // reads as `compat`, i.e. the v1.10.3 rules.
      settings.imageFormat = ImageFormatPreference.fromName(
        data.settings.imageFormat,
      );

      // Union merge for usedAlbumNames:
      final mergedAlbums = <String>{
        ...settings.usedAlbumNames,
        ...data.settings.usedAlbumNames,
      };
      settings.usedAlbumNames = mergedAlbums.toList();

      // v1.11 batch 1: the backup records whether auto folder backup was on
      // and the folder's display name, never the URI grant. Restoring leaves
      // the switch off; the page then asks the user and re-authorises the
      // folder (AutoBackupResume). A pre-v1.11 backup has neither field, so
      // the current setting is left untouched.
      if (data.settings.hasAutoBackupFields) {
        settings.autoFolderBackupEnabled = false;
      }

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
      restoredItems: restoredItemsCount,
      restoredSettings: restoreSettings,
      overlayNotice: overlayNotice,
      insertedPosts: insertedPosts,
      mergedPosts: mergedPosts,
      skippedPosts: skippedPosts,
      notOnDevice: notOnDevice,
      notOnDeviceItems: notOnDeviceItemsCount,
    );
  }
}
