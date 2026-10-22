// Gallery locator service: scans EasySave album using photo_manager,
// builds in-memory filename/postId index once per session, and locates
// saved files for history records without repeated disk queries.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import 'history_db.dart';
import 'settings.dart';

class GalleryLocatorService extends ChangeNotifier {
  GalleryLocatorService._();

  static final GalleryLocatorService instance = GalleryLocatorService._();

  PermissionState _permission = PermissionState.notDetermined;
  PermissionState get permission => _permission;

  bool get isFullyAuthorized => _permission == PermissionState.authorized;
  bool get isLimited => _permission == PermissionState.limited;
  bool get hasAccess => _permission.hasAccess;
  bool get isDenied =>
      _permission == PermissionState.denied ||
      _permission == PermissionState.restricted;

  bool _scanned = false;
  bool get scanned => _scanned;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final Map<String, AssetEntity> _exactMap = {};
  final Map<String, AssetEntity> _idMap = {};
  final List<AssetEntity> _allAssets = [];

  static const _defaultOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  AssetEntity? getAssetById(String? mediaId) {
    if (mediaId == null || mediaId.isEmpty) return null;
    return _idMap[mediaId];
  }

  /// Preload AssetEntities for known mediaIds without scanning entire album.
  Future<void> preloadMediaIds(List<HistoryRecord> records) async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return;
    }
    final idsToFetch = <String>{};
    for (final r in records) {
      for (final f in r.files) {
        final id = f.mediaId;
        if (id != null && id.isNotEmpty && !_idMap.containsKey(id)) {
          idsToFetch.add(id);
        }
      }
    }
    if (idsToFetch.isEmpty) return;
    final futures = idsToFetch.map((id) async {
      try {
        final asset = await AssetEntity.fromId(id);
        if (asset != null) {
          _idMap[id] = asset;
          if (asset.title != null && asset.title!.isNotEmpty) {
            _exactMap[asset.title!.toLowerCase()] = asset;
          }
        }
      } catch (_) {}
    });
    await Future.wait(futures);
    notifyListeners();
  }

  /// Check current permission state without prompting the user.
  Future<PermissionState> checkPermission() async {
    try {
      _permission = await PhotoManager.getPermissionState(requestOption: _defaultOption);
      notifyListeners();
    } catch (e) {
      debugPrint('GalleryLocatorService.checkPermission error: $e');
    }
    return _permission;
  }

  /// Request album access up-front if the user hasn't granted it yet. Used at
  /// cold start so the first history/open is instant instead of prompting
  /// mid-flow. Android reports the never-asked state inconsistently (sometimes
  /// `denied`), so we request whenever access is missing; if the user has
  /// permanently denied, the OS simply returns without showing a dialog.
  Future<void> ensurePermission() async {
    await checkPermission();
    if (!_permission.hasAccess) {
      await requestPermission();
    }
  }

  /// Request photo permission. If granted, automatically triggers album scan.
  Future<PermissionState> requestPermission() async {
    try {
      _permission = await PhotoManager.requestPermissionExtend(requestOption: _defaultOption);
      notifyListeners();
      if (_permission.hasAccess) {
        await scanAlbum();
      }
    } catch (e) {
      debugPrint('GalleryLocatorService.requestPermission error: $e');
    }
    return _permission;
  }

  /// Present picker to add more items in Android 14 / iOS limited permission mode.
  Future<void> reRequestLimited() async {
    try {
      await PhotoManager.presentLimited();
      _permission = await PhotoManager.getPermissionState(requestOption: _defaultOption);
      notifyListeners();
      if (_permission.hasAccess) {
        await scanAlbum(force: true);
      }
    } catch (e) {
      debugPrint('GalleryLocatorService.reRequestLimited error: $e');
    }
  }

  /// Open application settings.
  Future<void> openSettings() async {
    try {
      await PhotoManager.openSetting();
    } catch (e) {
      debugPrint('GalleryLocatorService.openSettings error: $e');
    }
  }

  /// Scan the album once per session and build in-memory index.
  Future<void> scanAlbum({bool force = false}) async {
    if (!hasAccess) return;
    if (_scanned && !force) return;
    if (_isScanning) return;

    _isScanning = true;
    notifyListeners();

    try {
      final settings = await AppSettings.load();
      final albumName = settings.albumName.trim().toLowerCase();

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
        // Without `needTitle`, AssetEntity.title is null on Android, so every
        // filename-based match fails and saved files look "deleted".
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
          videoOption: const FilterOption(needTitle: true),
        ),
      );

      AssetPathEntity? targetAlbum;
      AssetPathEntity? allAlbum;

      for (final p in paths) {
        if (p.isAll) {
          allAlbum = p;
        }
        if (p.name.trim().toLowerCase() == albumName) {
          targetAlbum = p;
        }
      }

      final assetsToIndex = <AssetEntity>[];

      if (targetAlbum != null) {
        final count = await targetAlbum.assetCountAsync;
        if (count > 0) {
          final list = await targetAlbum.getAssetListRange(
            start: 0,
            end: count,
          );
          assetsToIndex.addAll(list);
        }
      }

      // In limited mode, or if target album was not found/empty, load from allAlbum
      if ((isLimited || assetsToIndex.isEmpty) && allAlbum != null) {
        final count = await allAlbum.assetCountAsync;
        if (count > 0) {
          final list = await allAlbum.getAssetListRange(start: 0, end: count);
          for (final a in list) {
            if (!assetsToIndex.any((existing) => existing.id == a.id)) {
              assetsToIndex.add(a);
            }
          }
        }
      }

      _exactMap.clear();
      _idMap.clear();
      _allAssets.clear();

      for (final asset in assetsToIndex) {
        _idMap[asset.id] = asset;
        _allAssets.add(asset);

        final title = (asset.title ?? '').trim().toLowerCase();
        if (title.isNotEmpty) {
          _exactMap[title] = asset;

          // Strip directory path if title has any
          final baseName = title.split('/').last.split('\\').last;
          _exactMap[baseName] = asset;
        }
      }

      _scanned = true;
    } catch (e) {
      debugPrint('GalleryLocatorService.scanAlbum error: $e');
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Exact album lookup by a file's base name (no extension). Unlike
  /// [locateAsset] this never fuzzy-matches, so it is safe to use as an
  /// idempotency guard: "is a file with this name already in the album?"
  AssetEntity? assetByBaseName(String baseName) {
    if (!hasAccess) return null;
    final key = baseName.trim().toLowerCase();
    if (key.isEmpty) return null;
    return _exactMap[key];
  }

  /// Locate asset for a HistoryFile.
  /// 1. Try mediaId
  /// 2. Try exact filename match (case-insensitive, handling double extension variants)
  /// 3. Fuzzy match: album assets containing postId
  AssetEntity? locateAsset(HistoryFile file, String postId) {
    if (file.mediaId != null && _idMap.containsKey(file.mediaId)) {
      return _idMap[file.mediaId];
    }

    final fn = file.filename.trim().toLowerCase();
    if (fn.isNotEmpty) {
      if (_exactMap.containsKey(fn)) {
        return _exactMap[fn];
      }
      // Handle possible .jpg.jpg / .mp4.mp4 from older download sheet bug
      if (fn.endsWith('.jpg.jpg')) {
        final fixed = fn.substring(0, fn.length - 4);
        if (_exactMap.containsKey(fixed)) return _exactMap[fixed];
      } else if (fn.endsWith('.mp4.mp4')) {
        final fixed = fn.substring(0, fn.length - 4);
        if (_exactMap.containsKey(fixed)) return _exactMap[fixed];
      } else if (fn.endsWith('.jpg')) {
        final doubleExt = '$fn.jpg';
        if (_exactMap.containsKey(doubleExt)) return _exactMap[doubleExt];
      } else if (fn.endsWith('.mp4')) {
        final doubleExt = '$fn.mp4';
        if (_exactMap.containsKey(doubleExt)) return _exactMap[doubleExt];
      }
    }

    // Fuzzy matching by postId in filename
    final cleanPostId = postId.trim().toLowerCase();
    if (cleanPostId.isNotEmpty) {
      final matches = _allAssets.where((a) {
        final t = (a.title ?? '').toLowerCase();
        return t.contains(cleanPostId);
      }).toList();

      if (matches.isNotEmpty) {
        final isImage = fn.endsWith('.jpg') ||
            fn.endsWith('.png') ||
            fn.endsWith('.jpeg') ||
            fn.endsWith('.webp');
        final isVideo =
            fn.endsWith('.mp4') || fn.endsWith('.mov') || fn.endsWith('.webm');

        final typeMatches = matches.where((a) {
          if (isImage) return a.type == AssetType.image;
          if (isVideo) return a.type == AssetType.video;
          return true;
        }).toList();

        final pool = typeMatches.isNotEmpty ? typeMatches : matches;

        // If filename contains sequence pattern like '_1.' or '_2.', try to match it
        final seqMatch = RegExp(r'[_ -](\d+)\.').firstMatch(fn);
        if (seqMatch != null) {
          final seq = seqMatch.group(1)!;
          final withSeq = pool.where((a) {
            final t = (a.title ?? '').toLowerCase();
            return t.contains('_$seq.') ||
                t.contains('-$seq.') ||
                t.contains(' $seq.');
          }).toList();
          if (withSeq.isNotEmpty) return withSeq.first;
        }

        return pool.first;
      }
    }

    return null;
  }

  /// Synchronize file statuses and mediaIds for a history record.
  /// Updates database if any state changes.
  Future<void> syncRecord(HistoryRecord record) async {
    var changed = false;
    final updatedFiles = <HistoryFile>[];

    for (final file in record.files) {
      final asset = locateAsset(file, record.postId);
      if (asset != null) {
        if (file.mediaId != asset.id || file.status != FileStatus.found) {
          updatedFiles.add(file.copyWith(
            mediaId: asset.id,
            status: FileStatus.found,
          ));
          changed = true;
        } else {
          updatedFiles.add(file);
        }
      } else {
        if (isFullyAuthorized) {
          if (file.status != FileStatus.notFound) {
            updatedFiles.add(file.copyWith(status: FileStatus.notFound));
            changed = true;
          } else {
            updatedFiles.add(file);
          }
        } else {
          // If permission is limited, denied, or notDetermined, keep unknown
          if (file.status != FileStatus.unknown) {
            updatedFiles.add(file.copyWith(status: FileStatus.unknown));
            changed = true;
          } else {
            updatedFiles.add(file);
          }
        }
      }
    }

    if (changed && record.id != null) {
      record.files.clear();
      record.files.addAll(updatedFiles);
      final db = await HistoryDb.instance();
      await db.updateFiles(record.id!, updatedFiles);
    }
  }

  /// Sync all records in the list against the scanned album.
  Future<void> syncAll(List<HistoryRecord> records) async {
    for (final record in records) {
      await syncRecord(record);
    }
  }

  /// Return the set of item indices for [post] that are already saved locally.
  Future<Set<int>> findDownloadedIndices(ParsedPost post) async =>
      (await matchPostItems(post)).keys.toSet();

  /// Locate the album asset behind each item of [post] (index -> asset) using
  /// the persisted history record first, then a postId + sequence scan.
  Future<Map<int, AssetEntity>> matchPostItems(ParsedPost post) async {
    final result = <int, AssetEntity>{};
    try {
      if (hasAccess && !_scanned) {
        await scanAlbum();
      }
      final db = await HistoryDb.instance();
      final record = await db.getByPostId(post.id);
      if (record != null && record.files.isNotEmpty) {
        for (final file in record.files) {
          final asset = locateAsset(file, post.id);
          if (asset != null) {
            result[file.itemIndex] = asset;
          }
        }
      }

      // Check album assets for matches by postId and sequence.
      final cleanPostId = post.id.trim().toLowerCase();
      if (cleanPostId.isNotEmpty) {
        final matches = _allAssets.where((a) {
          final t = (a.title ?? '').toLowerCase();
          return t.contains(cleanPostId);
        }).toList();

        if (matches.isNotEmpty) {
          for (var i = 0; i < post.items.length; i++) {
            if (result.containsKey(i)) continue;
            final it = post.items[i];
            final isImage = it.type != 'video';
            final seq = i + 1;
            final matched = matches.where((a) {
              if (isImage && a.type != AssetType.image) return false;
              if (!isImage && a.type != AssetType.video) return false;
              if (post.items.length == 1) return true;
              final t = (a.title ?? '').toLowerCase();
              return t.contains('_$seq.') ||
                  t.contains('-$seq.') ||
                  t.contains(' $seq.');
            }).toList();
            if (matched.isNotEmpty) {
              result[i] = matched.first;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('matchPostItems error: $e');
    }
    return result;
  }

  /// Link already-saved local album files to [post] in the history database
  /// without downloading them again. Returns the number of files associated.
  ///
  /// This is a **user-initiated save** ("保存" on the preview page when every
  /// selected file is already in the album), so the record is written with
  /// `restoreDeleted: true`: a record the user deleted earlier must come back
  /// when they save the same post again. Recovery paths never call this.
  ///
  /// [matches] can be supplied by callers that already resolved the album
  /// assets (the preview page scans once and reuses the result), and by tests.
  /// [db] overrides the history store (tests); production uses the app store.
  ///
  /// [restoreDeleted] has no default on purpose: every caller must state
  /// whether the record it writes may resurrect a record the user deleted.
  /// Only a user-initiated save passes true; recovery paths must not.
  Future<int> associateExisting(
    ParsedPost post,
    List<int> indices, {
    required bool restoreDeleted,
    Map<int, AssetEntity>? matches,
    HistoryDb? db,
  }) async {
    final resolved = matches ?? await matchPostItems(post);
    final now = DateTime.now().millisecondsSinceEpoch;
    final files = <HistoryFile>[];
    for (final i in indices) {
      final asset = resolved[i];
      if (asset == null) continue;
      files.add(
        HistoryFile(
          filename: asset.title ?? '',
          savedAt: now,
          mediaId: asset.id,
          itemIndex: i,
          isImage: asset.type == AssetType.image,
          status: FileStatus.found,
        ),
      );
    }
    if (files.isEmpty) return 0;
    final store = db ?? await HistoryDb.instance();
    DevLog.write(
      'V16DL', // i18n:ignore 日志
      'history write post=${post.id} source=associate-existing '
      'restoreDeleted=$restoreDeleted files=${files.length}',
    );
    await store.upsert(
      HistoryRecord(
        platform: post.platform,
        postId: post.id,
        authorName: post.author.name,
        title: post.title,
        caption: post.caption,
        postUrl: post.url,
        fileCount: files.length,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([for (final it in post.items) it.toJson()]),
        files: files,
      ),
      restoreDeleted: restoreDeleted,
    );
    return files.length;
  }

  /// Returns all scanned assets for rebuild purposes.
  /// Only valid after [scanAlbum] has been called.
  List<AssetEntity> getScannedAssets() => List.unmodifiable(_allAssets);
}

