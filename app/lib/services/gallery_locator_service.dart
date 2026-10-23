// Gallery locator service: scans EasySave album using photo_manager,
// builds in-memory filename/postId index once per session, and locates
// saved files for history records without repeated disk queries.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../metadata/metadata_service.dart';
import '../metadata/url_normalizer.dart';
import '../metadata/xmp_model.dart';
import 'history_db.dart';
import 'media_header_service.dart';
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
  final Map<String, String?> _relPathMap = {};
  final Map<String, XmpProvenance?> _xmpCache = {};

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

  /// Asynchronously retrieve AssetEntity by mediaId, querying MediaStore if not cached.
  Future<AssetEntity?> getAssetByIdAsync(String? mediaId) async {
    if (mediaId == null || mediaId.isEmpty) return null;
    if (_idMap.containsKey(mediaId)) return _idMap[mediaId];
    if (!hasAccess) return null;
    try {
      final asset = await AssetEntity.fromId(mediaId);
      if (asset != null) {
        _idMap[mediaId] = asset;
        if (asset.title != null && asset.title!.isNotEmpty) {
          _exactMap[asset.title!.toLowerCase()] = asset;
        }
        return asset;
      }
    } catch (_) {}
    return null;
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

  /// Evict deleted media IDs from in-memory caches.
  void evictMediaIds(Iterable<String> ids) {
    for (final id in ids) {
      final asset = _idMap.remove(id);
      final title = (asset?.title ?? '').trim().toLowerCase();
      if (title.isNotEmpty) {
        _exactMap.remove(title);
        final baseName = title.split('/').last.split('\\').last;
        _exactMap.remove(baseName);
      }
      _allAssets.removeWhere((a) => a.id == id);
    }
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
      // Every album the app has used, not just the current one: renaming the
      // album must not hide the files that were saved before the rename.
      final wanted = {
        for (final name in settings.effectiveAlbumNames) name.trim().toLowerCase(),
      };

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

      AssetPathEntity? allAlbum;

      for (final p in paths) {
        if (p.isAll) allAlbum = p;
      }

      final assetsToIndex = <AssetEntity>[];
      final seenIds = <String>{};

      for (final p in paths) {
        if (p.isAll) continue;
        if (!wanted.contains(p.name.trim().toLowerCase())) continue;
        final count = await p.assetCountAsync;
        if (count <= 0) continue;
        final list = await p.getAssetListRange(start: 0, end: count);
        for (final asset in list) {
          if (seenIds.add(asset.id)) assetsToIndex.add(asset);
        }
      }

      // Only when no used album exists at all (fresh install with the album
      // not created yet) fall back to the whole library, so the app is never
      // left unable to locate its own files.
      if (assetsToIndex.isEmpty && allAlbum != null) {
        DevLog.write(
          'V16DL', // i18n:ignore 日志
          'no used album found ($albumName), falling back to the whole library',
          level: DevLogLevel.warn,
        );
        final count = await allAlbum.assetCountAsync;
        if (count > 0) {
          final list = await allAlbum.getAssetListRange(start: 0, end: count);
          for (final a in list) {
            if (seenIds.add(a.id)) assetsToIndex.add(a);
          }
        }
      }

      _exactMap.clear();
      _idMap.clear();
      _allAssets.clear();
      _relPathMap.clear();
      _xmpCache.clear();

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

  /// Testing hook to inject pre-scanned assets and permission state.
  @visibleForTesting
  void setScannedForTesting({
    required bool scanned,
    required PermissionState permission,
    List<AssetEntity>? assets,
    Map<String, String?>? relativePaths,
  }) {
    _scanned = scanned;
    _permission = permission;
    _exactMap.clear();
    _idMap.clear();
    _allAssets.clear();
    _relPathMap.clear();
    _xmpCache.clear();
    if (assets != null) {
      for (final a in assets) {
        _idMap[a.id] = a;
        _allAssets.add(a);
        final title = (a.title ?? '').trim().toLowerCase();
        if (title.isNotEmpty) {
          _exactMap[title] = a;
          final baseName = title.split('/').last.split('\\').last;
          _exactMap[baseName] = a;
        }
      }
    }
    if (relativePaths != null) {
      _relPathMap.addAll(relativePaths);
    }
    notifyListeners();
  }

  /// Testing hook to reset locator state.
  @visibleForTesting
  void resetForTesting() {
    _scanned = false;
    _isScanning = false;
    _permission = PermissionState.notDetermined;
    _exactMap.clear();
    _idMap.clear();
    _allAssets.clear();
    _relPathMap.clear();
    _xmpCache.clear();
  }

  /// Normalize directory/file paths for consistent comparison (e.g.,
  /// "Pictures/EasySave/" -> "pictures/easysave").
  static String normalizePath(String path) {
    var p = path.replaceAll('\\', '/').trim().toLowerCase();
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// Query or return cached MediaStore RELATIVE_PATH for an asset.
  Future<String?> getRelativePath(AssetEntity asset) async {
    if (_relPathMap.containsKey(asset.id)) {
      return _relPathMap[asset.id];
    }
    var rel = asset.relativePath;
    if (rel == null || rel.isEmpty) {
      try {
        final info = await MediaHeaderService.queryAlbum(asset.id);
        rel = info?.relativePath;
      } catch (_) {}
    }
    _relPathMap[asset.id] = rel;
    return rel;
  }

  static bool _matchesDoubleExtension(String candidateName, String targetName) {
    if (targetName.endsWith('.jpg.jpg')) {
      return candidateName == targetName.substring(0, targetName.length - 4);
    }
    if (targetName.endsWith('.mp4.mp4')) {
      return candidateName == targetName.substring(0, targetName.length - 4);
    }
    if (candidateName.endsWith('.jpg.jpg')) {
      return candidateName.substring(0, candidateName.length - 4) == targetName;
    }
    if (candidateName.endsWith('.mp4.mp4')) {
      return candidateName.substring(0, candidateName.length - 4) == targetName;
    }
    return false;
  }

  /// Check XMP provenance consistency for Level 2 and Level 3 matches.
  ///
  /// Rules:
  /// 1. If file has no readable XMP, allow association (filename-only).
  /// 2. If file contains XMP, it MUST match either expectedAssetId or
  ///    (platform + sourceId == expectedPostId). Files with conflicting XMP
  ///    MUST NOT be associated.
  Future<bool> _verifyXmpConsistency(
    AssetEntity asset, {
    String? expectedAssetId,
    String? expectedPlatform,
    required String expectedPostId,
  }) async {
    try {
      XmpProvenance? prov = _xmpCache[asset.id];
      if (!_xmpCache.containsKey(asset.id)) {
        final mime = asset.type == AssetType.video ? 'video/mp4' : 'image/jpeg';
        final bytes = await MediaHeaderService.readHeader(asset.id, mime);
        if (bytes.isNotEmpty) {
          prov = MetadataService.readProvenanceFromBytes(bytes);
        }
        _xmpCache[asset.id] = prov;
      }

      // 只有无 XMP 的文件才允许仅凭文件名关联。
      if (prov == null) {
        return true;
      }

      // 文件含 XMP，必须用 MediaHeaderReader 读出的 assetId 或 platform+sourceId 核对一致，才能关联；
      // XMP 不一致的文件不得关联（常见文件名会重名）。
      if (expectedAssetId != null &&
          expectedAssetId.isNotEmpty &&
          prov.assetId.isNotEmpty &&
          prov.assetId == expectedAssetId) {
        return true;
      }

      if (prov.platform != null &&
          prov.sourceId != null &&
          prov.sourceId == expectedPostId) {
        if (expectedPlatform != null && expectedPlatform.isNotEmpty) {
          if (toSpecPlatform(prov.platform!) == toSpecPlatform(expectedPlatform)) {
            return true;
          }
        } else {
          return true;
        }
      }

      // XMP is present but does not match assetId or platform+sourceId!
      return false;
    } catch (e) {
      DevLog.write('GalleryLocator', 'Error checking XMP: $e');
      return true;
    }
  }

  /// Locate asset asynchronously with multi-level fallback and XMP validation:
  /// 1. relativePath + filename exact match
  /// 2. usedAlbumNames + filename (validated by XMP)
  /// 3. postId sequence fuzzy match (validated by XMP)
  Future<AssetEntity?> locateAssetAsync(
    HistoryFile file,
    String postId, {
    String? platform,
  }) async {
    // 0. If mediaId is known, check cached or fetch fromId directly
    if (file.mediaId != null && file.mediaId!.isNotEmpty) {
      var cached = _idMap[file.mediaId];
      if (cached == null && hasAccess) {
        try {
          cached = await AssetEntity.fromId(file.mediaId!);
          if (cached != null) {
            _idMap[file.mediaId!] = cached;
            if (cached.title != null && cached.title!.isNotEmpty) {
              _exactMap[cached.title!.toLowerCase()] = cached;
            }
          }
        } catch (_) {}
      }
      if (cached != null) {
        bool exists = true;
        try {
          exists = await cached.exists;
        } catch (_) {}
        if (exists) {
          final title = (cached.title ?? '').trim().toLowerCase();
          final baseName = title.split('/').last.split('\\').last;
          final targetName = file.filename.trim().toLowerCase();
          if (targetName.isEmpty ||
              title == targetName ||
              baseName == targetName ||
              _matchesDoubleExtension(baseName, targetName)) {
            return cached;
          }
        } else {
          evictMediaIds([cached.id]);
        }
      }
    }

    // Priority 1: relativePath + filename
    if (file.relativePath != null && file.relativePath!.trim().isNotEmpty) {
      final targetRel = normalizePath(file.relativePath!);
      final targetName = file.filename.trim().toLowerCase();

      for (final asset in _allAssets) {
        final title = (asset.title ?? '').trim().toLowerCase();
        final baseName = title.split('/').last.split('\\').last;
        if (title == targetName ||
            baseName == targetName ||
            _matchesDoubleExtension(baseName, targetName)) {
          final rel = await getRelativePath(asset);
          if (rel != null && normalizePath(rel) == targetRel) {
            _idMap[asset.id] = asset;
            return asset;
          }
        }
      }
    }

    // Priority 2: usedAlbumNames + filename
    final targetName = file.filename.trim().toLowerCase();
    if (targetName.isNotEmpty) {
      final candidates = <AssetEntity>[];
      for (final asset in _allAssets) {
        final title = (asset.title ?? '').trim().toLowerCase();
        final baseName = title.split('/').last.split('\\').last;
        if (title == targetName ||
            baseName == targetName ||
            _matchesDoubleExtension(baseName, targetName)) {
          candidates.add(asset);
        }
      }

      for (final candidate in candidates) {
        final isConsistent = await _verifyXmpConsistency(
          candidate,
          expectedAssetId: file.assetId,
          expectedPlatform: platform,
          expectedPostId: postId,
        );
        if (isConsistent) {
          _idMap[candidate.id] = candidate;
          return candidate;
        }
      }
    }

    // Priority 3: postId fuzzy match
    final cleanPostId = postId.trim().toLowerCase();
    if (cleanPostId.isNotEmpty) {
      final matches = _allAssets.where((a) {
        final t = (a.title ?? '').toLowerCase();
        return t.contains(cleanPostId);
      }).toList();

      if (matches.isNotEmpty) {
        final fn = file.filename.trim().toLowerCase();
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

        // Sequence ordering
        final seqMatch = RegExp(r'[_ -](\d+)\.').firstMatch(fn);
        List<AssetEntity> orderedCandidates = pool;
        if (seqMatch != null) {
          final seq = seqMatch.group(1)!;
          final withSeq = pool.where((a) {
            final t = (a.title ?? '').toLowerCase();
            return t.contains('_$seq.') ||
                t.contains('-$seq.') ||
                t.contains(' $seq.');
          }).toList();
          if (withSeq.isNotEmpty) {
            orderedCandidates = [
              ...withSeq,
              ...pool.where((a) => !withSeq.contains(a)),
            ];
          }
        }

        for (final candidate in orderedCandidates) {
          final isConsistent = await _verifyXmpConsistency(
            candidate,
            expectedAssetId: file.assetId,
            expectedPlatform: platform,
            expectedPostId: postId,
          );
          if (isConsistent) {
            _idMap[candidate.id] = candidate;
            return candidate;
          }
        }
      }
    }

    return null;
  }

  /// Locate asset for a HistoryFile synchronously using cached assets.
  AssetEntity? locateAsset(HistoryFile file, String postId) {
    if (file.mediaId != null && _idMap.containsKey(file.mediaId)) {
      return _idMap[file.mediaId];
    }

    // Priority 1: cached relativePath + filename
    if (file.relativePath != null && file.relativePath!.trim().isNotEmpty) {
      final targetRel = normalizePath(file.relativePath!);
      final targetName = file.filename.trim().toLowerCase();
      for (final asset in _allAssets) {
        final title = (asset.title ?? '').trim().toLowerCase();
        final baseName = title.split('/').last.split('\\').last;
        if (title == targetName ||
            baseName == targetName ||
            _matchesDoubleExtension(baseName, targetName)) {
          final rel = _relPathMap[asset.id] ?? asset.relativePath;
          if (rel != null && normalizePath(rel) == targetRel) {
            return asset;
          }
        }
      }
    }

    // Priority 2: exact filename match
    final fn = file.filename.trim().toLowerCase();
    if (fn.isNotEmpty) {
      if (_exactMap.containsKey(fn)) {
        final candidate = _exactMap[fn]!;
        final prov = _xmpCache[candidate.id];
        if (prov == null ||
            (file.assetId != null && prov.assetId == file.assetId) ||
            prov.sourceId == postId) {
          return candidate;
        }
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

    // Priority 3: Fuzzy matching by postId in filename
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
  /// Note: Records where files cannot be found are preserved in DB (never deleted).
  Future<void> syncRecord(HistoryRecord record) async {
    var changed = false;
    final updatedFiles = <HistoryFile>[];

    for (final file in record.files) {
      final asset = await locateAssetAsync(
        file,
        record.postId,
        platform: record.platform,
      );
      if (asset != null) {
        String? newRelPath = file.relativePath;
        if (newRelPath == null || newRelPath.isEmpty) {
          newRelPath = await getRelativePath(asset);
        }
        if (file.mediaId != asset.id ||
            file.status != FileStatus.found ||
            (newRelPath != null && file.relativePath != newRelPath)) {
          updatedFiles.add(file.copyWith(
            mediaId: asset.id,
            status: FileStatus.found,
            relativePath: newRelPath,
          ));
          changed = true;
        } else {
          updatedFiles.add(file);
        }
      } else {
        if (isFullyAuthorized && _scanned) {
          if (file.status != FileStatus.notFound) {
            updatedFiles.add(file.copyWith(status: FileStatus.notFound));
            changed = true;
          } else {
            updatedFiles.add(file);
          }
        } else {
          // If permission is limited, denied, notDetermined, or album not scanned yet, keep unknown
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
      if (record != null && !record.isDeleted && record.files.isNotEmpty) {
        final is1Based = record.files.every((f) => f.itemIndex > 0);
        for (final file in record.files) {
          final asset = await locateAssetAsync(
            file,
            post.id,
            platform: record.platform,
          );
          if (asset != null) {
            bool exists = true;
            try {
              exists = await asset.exists;
            } catch (_) {}
            if (!exists) {
              evictMediaIds([asset.id]);
              continue;
            }
            final zeroBased = is1Based ? file.itemIndex - 1 : file.itemIndex;
            result[zeroBased] = asset;
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
              final candidate = matched.first;
              bool exists = true;
              try {
                exists = await candidate.exists;
              } catch (_) {}
              if (exists) {
                result[i] = candidate;
              } else {
                evictMediaIds([candidate.id]);
              }
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
          itemIndex: i + 1,
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

  /// Albums present on the device with their image counts.
  ///
  /// Used by the rebuild picker: the used albums are pre-selected, and other
  /// albums can be added explicitly (a full-device scan is much slower).
  Future<List<({String name, int count})>> albumOptions() async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return const [];
    }
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: false,
      );
      final options = <({String name, int count})>[];
      for (final path in paths) {
        if (path.isAll) continue;
        final count = await path.assetCountAsync;
        options.add((name: path.name, count: count));
      }
      return options;
    } catch (e) {
      debugPrint('albumOptions error: $e');
      return const [];
    }
  }

  /// Total number of images on the device (the "全部相册" option).
  Future<int> allAlbumCount() async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return 0;
    }
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
      );
      for (final path in paths) {
        if (path.isAll) return await path.assetCountAsync;
      }
    } catch (e) {
      debugPrint('allAlbumCount error: $e');
    }
    return 0;
  }

  /// Assets of [albumNames] (case-insensitive).
  ///
  /// Reads straight from MediaStore and does not touch the shared locator
  /// index: the rebuild scan must not leave the app pointing at a different
  /// set of assets than [scanAlbum] would.
  Future<List<AssetEntity>> assetsInAlbums(Iterable<String> albumNames) async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return const [];
    }
    final wanted = {
      for (final name in albumNames)
        if (name.trim().isNotEmpty) name.trim().toLowerCase(),
    };
    if (wanted.isEmpty) return const [];
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: false,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
        ),
      );
      final assets = <AssetEntity>[];
      final seen = <String>{};
      for (final path in paths) {
        if (path.isAll) continue;
        if (!wanted.contains(path.name.trim().toLowerCase())) continue;
        final count = await path.assetCountAsync;
        if (count <= 0) continue;
        final list = await path.getAssetListRange(start: 0, end: count);
        for (final asset in list) {
          if (seen.add(asset.id)) assets.add(asset);
        }
      }
      return assets;
    } catch (e) {
      debugPrint('assetsInAlbums error: $e');
      return const [];
    }
  }

  /// Every image on the device (explicit "全部相册" rebuild only).
  Future<List<AssetEntity>> allImages() async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return const [];
    }
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
        ),
      );
      for (final path in paths) {
        if (path.isAll) {
          final count = await path.assetCountAsync;
          if (count <= 0) return const [];
          return path.getAssetListRange(start: 0, end: count);
        }
      }
    } catch (e) {
      debugPrint('allImages error: $e');
    }
    return const [];
  }
}

