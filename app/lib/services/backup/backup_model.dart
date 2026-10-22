// Copyright 2026 EasySave. All rights reserved.
// Data models for backup and restore (matching spec/backup.md §2).

import '../../metadata/provenance_version.dart' as pv;

class IncompatibleBackupVersionException implements Exception {
  final int version;
  IncompatibleBackupVersionException(this.version);

  @override
  String toString() =>
      'IncompatibleBackupVersionException: version $version is not supported (requires app update)';
}

class BackupFile {
  final String filename;
  final String? relativePath;
  final String savedAt;
  final String mediaType;
  final String? mediaId;
  final int itemIndex;
  final String? assetId;
  final Map<String, dynamic>? provenance;

  BackupFile({
    required this.filename,
    this.relativePath,
    required this.savedAt,
    required this.mediaType,
    this.mediaId,
    required this.itemIndex,
    this.assetId,
    this.provenance,
  });

  Map<String, dynamic> toMap() => {
        'filename': filename,
        if (relativePath != null) 'relativePath': relativePath,
        'savedAt': savedAt,
        'mediaType': mediaType,
        if (mediaId != null) 'mediaId': mediaId,
        'itemIndex': itemIndex,
        if (assetId != null) 'assetId': assetId,
        if (provenance != null) 'provenance': provenance,
      };

  factory BackupFile.fromMap(Map<String, dynamic> map) {
    return BackupFile(
      filename: map['filename'] as String? ?? '',
      relativePath: map['relativePath'] as String?,
      savedAt: map['savedAt'] as String? ?? '',
      mediaType: map['mediaType'] as String? ?? 'image',
      mediaId: map['mediaId'] as String?,
      itemIndex: (map['itemIndex'] as num?)?.toInt() ?? 1,
      assetId: map['assetId'] as String?,
      provenance: (map['provenance'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

class BackupPost {
  final String platform;
  final String sourceId;
  final String originalUrl;
  final String? title;
  final String? authorName;
  final String? caption;
  final String createdAt;
  final List<Map<String, dynamic>>? items;
  final List<BackupFile> files;

  BackupPost({
    required this.platform,
    required this.sourceId,
    required this.originalUrl,
    this.title,
    this.authorName,
    this.caption,
    required this.createdAt,
    this.items,
    required this.files,
  });

  Map<String, dynamic> toMap() => {
        'platform': platform,
        'sourceId': sourceId,
        'originalUrl': originalUrl,
        if (title != null) 'title': title,
        if (authorName != null) 'authorName': authorName,
        if (caption != null) 'caption': caption,
        'createdAt': createdAt,
        if (items != null) 'items': items,
        'files': [for (final f in files) f.toMap()],
      };

  factory BackupPost.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>>? resolvedItems;
    final rawItems = map['items'];
    if (rawItems is List) {
      resolvedItems = [
        for (final item in rawItems)
          if (item is Map) item.cast<String, dynamic>(),
      ];
    }

    final rawFiles = map['files'];
    final resolvedFiles = <BackupFile>[];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        if (f is Map) {
          resolvedFiles.add(BackupFile.fromMap(f.cast<String, dynamic>()));
        }
      }
    }

    return BackupPost(
      platform: map['platform'] as String? ?? '',
      sourceId: map['sourceId'] as String? ?? '',
      originalUrl: map['originalUrl'] as String? ?? '',
      title: map['title'] as String?,
      authorName: map['authorName'] as String?,
      caption: map['caption'] as String?,
      createdAt: map['createdAt'] as String? ?? '',
      items: resolvedItems,
      files: resolvedFiles,
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
  static const currentFormatVersion = 1;
  static const currentAppVersion = '1.8.0';

  final String format;
  final int formatVersion;
  final String exportedAt;
  final String appVersion;
  final String provenanceSpecVersion;
  final BackupSettings settings;
  final List<BackupPost> posts;

  BackupData({
    this.format = currentFormat,
    this.formatVersion = currentFormatVersion,
    required this.exportedAt,
    this.appVersion = currentAppVersion,
    String? provenanceSpecVersion,
    required this.settings,
    required this.posts,
  }) : provenanceSpecVersion = provenanceSpecVersion ?? provenanceSpecVersionValue;

  static const provenanceSpecVersionValue = pv.provenanceSpecVersion;

  Map<String, dynamic> toMap() => {
        'format': format,
        'formatVersion': formatVersion,
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

    final formatVersion = (map['formatVersion'] as num?)?.toInt() ?? 1;
    if (formatVersion > currentFormatVersion) {
      throw IncompatibleBackupVersionException(formatVersion);
    }

    final rawSettings = map['settings'];
    final settings = (rawSettings is Map)
        ? BackupSettings.fromMap(rawSettings.cast<String, dynamic>())
        : BackupSettings();

    final rawPosts = map['posts'];
    final posts = <BackupPost>[];
    if (rawPosts is List) {
      for (final p in rawPosts) {
        if (p is Map) {
          posts.add(BackupPost.fromMap(p.cast<String, dynamic>()));
        }
      }
    }

    return BackupData(
      format: format,
      formatVersion: formatVersion,
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
