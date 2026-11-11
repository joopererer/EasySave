// Copyright 2026 EasySave. All rights reserved.
// Data models for backup and restore (spec/backup.md §2; schema v2 in
// docs/tasks/v1.10.md "备份格式 v2").
//
// Schema v2 keeps post identity, status and file identity only. Media,
// thumbnail and cover URLs (signed and expiring) are never written, and the
// only URL that may carry a query is the post's originalUrl. Reading a v1
// backup drops its URL-bearing fields (`items`, file `provenance`).

import '../../core/app_version.dart';
import '../../metadata/provenance_version.dart' as pv;

class IncompatibleBackupVersionException implements Exception {
  final int version;
  IncompatibleBackupVersionException(this.version);

  @override
  String toString() =>
      'IncompatibleBackupVersionException: version $version is not supported (requires app update)';
}

/// Download outcome of a post in a backup.
enum BackupPostStatus {
  success,
  partial,
  failed;

  static BackupPostStatus parse(Object? value) => BackupPostStatus.values
      .firstWhere((s) => s.name == value, orElse: () => BackupPostStatus.success);
}

class BackupFile {
  final int itemIndex;

  /// `image` or `video`.
  final String mediaType;

  /// Display name and relative path of the album file when it was saved.
  final String filename;
  final String? relativePath;

  /// Bytes of the saved file, when known.
  final int? size;

  /// prov:assetId written into the file.
  final String? assetId;

  /// MediaStore id on the device that wrote the backup. A hint only: a restore
  /// uses it after verifying the file's name and size.
  final String? mediaIdHint;
  final String savedAt;

  /// prov:itemCount and prov:capturedBy as written into the file, when known.
  final int? itemCount;
  final String? capturedBy;

  BackupFile({
    required this.itemIndex,
    required this.mediaType,
    required this.filename,
    this.relativePath,
    this.size,
    this.assetId,
    this.mediaIdHint,
    required this.savedAt,
    this.itemCount,
    this.capturedBy,
  });

  Map<String, dynamic> toMap() => {
        'itemIndex': itemIndex,
        'mediaType': mediaType,
        'filename': filename,
        if (relativePath != null) 'relativePath': relativePath,
        if (size != null) 'size': size,
        if (assetId != null) 'assetId': assetId,
        if (mediaIdHint != null) 'mediaIdHint': mediaIdHint,
        'savedAt': savedAt,
        if (itemCount != null) 'itemCount': itemCount,
        if (capturedBy != null) 'capturedBy': capturedBy,
      };

  /// Reads v2 files and v1 files. From v1 only identity fields are kept: its
  /// `provenance` object (which repeats the post URL) is reduced to
  /// itemCount and capturedBy, and `mediaId` becomes a hint.
  factory BackupFile.fromMap(Map<String, dynamic> map) {
    final provenance = map['provenance'];
    final source = provenance is Map ? provenance['source'] : null;
    return BackupFile(
      itemIndex: (map['itemIndex'] as num?)?.toInt() ?? (map['item_index'] as num?)?.toInt() ?? 1,
      mediaType: map['mediaType'] as String? ?? map['media_type'] as String? ?? 'image',
      filename: map['filename'] as String? ?? '',
      relativePath: map['relativePath'] as String? ?? map['relative_path'] as String?,
      size: (map['size'] as num?)?.toInt(),
      assetId: map['assetId'] as String? ?? map['asset_id'] as String?,
      mediaIdHint: map['mediaIdHint'] as String? ??
          map['mediaId'] as String? ??
          map['media_id'] as String?,
      savedAt: map['savedAt'] as String? ?? map['saved_at'] as String? ?? '',
      itemCount: (map['itemCount'] as num?)?.toInt() ??
          (source is Map ? (source['itemCount'] as num?)?.toInt() : null),
      capturedBy: map['capturedBy'] as String? ??
          (provenance is Map ? provenance['capturedBy'] as String? : null),
    );
  }
}

class BackupPost {
  /// Spec platform identity (e.g. `xiaohongshu`, `x`).
  final String platform;
  final String sourceId;

  /// Canonical post URL under the current provenance spec; never has a query.
  final String? canonicalUrl;

  /// The link as the user saved it, query included (e.g. xsec_token).
  final String originalUrl;
  final String? title;
  final String? authorName;
  final String? caption;
  final String? aiLabel;
  final String? aiLabelSource;

  /// When the post was saved (ISO 8601 with offset).
  final String savedAt;
  final BackupPostStatus status;

  /// Short failure reason for failed / partial posts.
  final String? failureReason;
  final List<BackupFile> files;

  BackupPost({
    required this.platform,
    required this.sourceId,
    this.canonicalUrl,
    required this.originalUrl,
    this.title,
    this.authorName,
    this.caption,
    this.aiLabel,
    this.aiLabelSource,
    required this.savedAt,
    this.status = BackupPostStatus.success,
    this.failureReason,
    required this.files,
  });

  Map<String, dynamic> toMap() => {
        'platform': platform,
        'sourceId': sourceId,
        if (canonicalUrl != null) 'canonicalUrl': canonicalUrl,
        'originalUrl': originalUrl,
        if (title != null) 'title': title,
        if (authorName != null) 'author': {'name': authorName},
        if (caption != null) 'caption': caption,
        if (aiLabel != null) 'aiLabel': aiLabel,
        if (aiLabelSource != null) 'aiLabelSource': aiLabelSource,
        'savedAt': savedAt,
        'status': status.name,
        if (failureReason != null) 'failureReason': failureReason,
        'files': [for (final f in files) f.toMap()],
      };

  /// Reads v2 posts and v1 posts. A v1 post's `items` (media and thumbnail
  /// URLs) is dropped; its status follows from its files.
  factory BackupPost.fromMap(Map<String, dynamic> map, {required int schemaVersion}) {
    final rawFiles = map['files'];
    final files = <BackupFile>[
      if (rawFiles is List)
        for (final f in rawFiles)
          if (f is Map) BackupFile.fromMap(f.cast<String, dynamic>()),
    ];
    final author = map['author'];
    return BackupPost(
      platform: map['platform'] as String? ?? '',
      sourceId: map['sourceId'] as String? ?? map['source_id'] as String? ?? '',
      canonicalUrl: map['canonicalUrl'] as String?,
      originalUrl: map['originalUrl'] as String? ?? map['original_url'] as String? ?? '',
      title: map['title'] as String?,
      authorName: (author is Map ? author['name'] as String? : null) ??
          map['authorName'] as String? ??
          map['author_name'] as String?,
      caption: map['caption'] as String?,
      aiLabel: map['aiLabel'] as String?,
      aiLabelSource: map['aiLabelSource'] as String?,
      savedAt: map['savedAt'] as String? ??
          map['createdAt'] as String? ??
          map['created_at'] as String? ??
          '',
      status: schemaVersion >= 2
          ? BackupPostStatus.parse(map['status'])
          : (files.isEmpty ? BackupPostStatus.failed : BackupPostStatus.success),
      failureReason: map['failureReason'] as String?,
      files: files,
    );
  }
}

class BackupSettings {
  final String albumName;
  final List<String> usedAlbumNames;
  final String namePattern;
  final bool saveProvenanceInImages;
  final bool bubbleEnabled;
  final bool bubbleAutoHide;
  final bool bubblePreviewSticky;
  final bool backgroundToast;
  final bool autoClipboard;
  final bool saveCaptionTxt;
  final String historyView;
  final String historyLayout;
  final String historySort;

  BackupSettings({
    this.albumName = 'EasySave',
    List<String>? usedAlbumNames,
    this.namePattern = '{id}_{seq}',
    this.saveProvenanceInImages = true,
    this.bubbleEnabled = false,
    this.bubbleAutoHide = true,
    this.bubblePreviewSticky = false,
    this.backgroundToast = true,
    this.autoClipboard = true,
    this.saveCaptionTxt = false,
    this.historyView = 'posts',
    this.historyLayout = 'waterfall',
    this.historySort = 'latest',
  }) : usedAlbumNames = usedAlbumNames != null
            ? List<String>.from(usedAlbumNames)
            : <String>[];

  Map<String, dynamic> toMap() => {
        'albumName': albumName,
        'usedAlbumNames': usedAlbumNames,
        'namePattern': namePattern,
        'saveProvenanceInImages': saveProvenanceInImages,
        'bubbleEnabled': bubbleEnabled,
        'bubbleAutoHide': bubbleAutoHide,
        'bubblePreviewSticky': bubblePreviewSticky,
        'backgroundToast': backgroundToast,
        'autoClipboard': autoClipboard,
        'saveCaptionTxt': saveCaptionTxt,
        'historyView': historyView,
        'historyLayout': historyLayout,
        'historySort': historySort,
      };

  factory BackupSettings.fromMap(Map<String, dynamic> map) {
    final rawAlbumNames = map['usedAlbumNames'];
    final albumList = <String>[];
    if (rawAlbumNames is List) {
      for (final a in rawAlbumNames) {
        if (a is String && a.trim().isNotEmpty) {
          albumList.add(a.trim());
        }
      }
    }

    return BackupSettings(
      albumName: map['albumName'] as String? ?? 'EasySave',
      usedAlbumNames: albumList,
      namePattern: map['namePattern'] as String? ?? '{id}_{seq}',
      saveProvenanceInImages: map['saveProvenanceInImages'] as bool? ?? true,
      bubbleEnabled: map['bubbleEnabled'] as bool? ?? false,
      bubbleAutoHide: map['bubbleAutoHide'] as bool? ?? true,
      bubblePreviewSticky: map['bubblePreviewSticky'] as bool? ?? false,
      backgroundToast: map['backgroundToast'] as bool? ?? true,
      autoClipboard: map['autoClipboard'] as bool? ?? true,
      saveCaptionTxt: map['saveCaptionTxt'] as bool? ?? false,
      historyView: map['historyView'] as String? ?? 'posts',
      historyLayout: map['historyLayout'] as String? ?? 'waterfall',
      historySort: map['historySort'] as String? ?? 'latest',
    );
  }
}

class BackupData {
  static const currentFormat = 'easysave-backup';

  /// Schema written by this App. v1 backups are still read.
  static const currentSchemaVersion = 2;

  /// Kept for callers of the v1 name.
  static const currentFormatVersion = currentSchemaVersion;

  /// Version string written into the backup header. It tracks the app that
  /// wrote the file; the old hard-coded value made every export claim 1.8.0.
  static const currentAppVersion = AppVersion.defaultVersion;

  final String format;
  final int schemaVersion;
  final String exportedAt;
  final String appVersion;
  final String provenanceSpecVersion;
  final BackupSettings settings;
  final List<BackupPost> posts;

  int get formatVersion => schemaVersion;

  BackupData({
    this.format = currentFormat,
    this.schemaVersion = currentSchemaVersion,
    required this.exportedAt,
    this.appVersion = currentAppVersion,
    String? provenanceSpecVersion,
    required this.settings,
    required this.posts,
  }) : provenanceSpecVersion = provenanceSpecVersion ?? provenanceSpecVersionValue;

  static const provenanceSpecVersionValue = pv.provenanceSpecVersion;

  /// `formatVersion` repeats the schema so an App that only knows v1 rejects
  /// a v2 file as "requires update" instead of misreading it.
  Map<String, dynamic> toMap() => {
        'format': format,
        'schemaVersion': schemaVersion,
        'formatVersion': schemaVersion,
        'exportedAt': exportedAt,
        'appVersion': appVersion,
        'provenanceSpecVersion': provenanceSpecVersion,
        'settings': settings.toMap(),
        'posts': [for (final p in posts) p.toMap()],
      };

  factory BackupData.fromMap(Map<String, dynamic> map) {
    final format = map['format'] as String? ?? '';
    if (format != currentFormat) {
      throw FormatException('Invalid backup format: expected "$currentFormat", got "$format"');
    }

    final schemaVersion = (map['schemaVersion'] as num?)?.toInt() ??
        (map['formatVersion'] as num?)?.toInt() ??
        1;
    if (schemaVersion > currentSchemaVersion) {
      throw IncompatibleBackupVersionException(schemaVersion);
    }

    final rawSettings = map['settings'];
    final settings = (rawSettings is Map)
        ? BackupSettings.fromMap(rawSettings.cast<String, dynamic>())
        : BackupSettings();

    final rawPosts = map['posts'];
    final posts = <BackupPost>[
      if (rawPosts is List)
        for (final p in rawPosts)
          if (p is Map)
            BackupPost.fromMap(p.cast<String, dynamic>(), schemaVersion: schemaVersion),
    ];

    return BackupData(
      format: format,
      schemaVersion: schemaVersion,
      exportedAt: map['exportedAt'] as String? ?? '',
      appVersion: map['appVersion'] as String? ?? currentAppVersion,
      provenanceSpecVersion: map['provenanceSpecVersion'] as String? ?? provenanceSpecVersionValue,
      settings: settings,
      posts: posts,
    );
  }
}

class BackupPreview {
  final String exportedAt;
  final String appVersion;
  final int postCount;
  final int fileCount;
  final BackupSettings? settings;
  final int formatVersion;

  BackupPreview({
    required this.exportedAt,
    required this.appVersion,
    required this.postCount,
    required this.fileCount,
    this.settings,
    required this.formatVersion,
  });
}
