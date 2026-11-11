import 'verified_media.dart';
import 'local_media.dart';
import 'media_load_gate.dart';
// Gallery locator service: scans EasySave album using photo_manager,
// builds in-memory filename/postId index once per session, and locates
// saved files for history records without repeated disk queries.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../metadata/metadata_service.dart';
import '../metadata/url_normalizer.dart';
import 'history_db.dart';
import 'media_header_service.dart';
import 'provenance_pair.dart';
import 'settings.dart';

class GalleryLocatorService extends ChangeNotifier {
  final Set<String> _unreadableIds = {};
  void markUnreadable(String id) {
    _unreadableIds.add(id);
    evictMediaIds([id]);
    notifyListeners();
  }
  Future<bool> isPresent(String id) async {
    if (_unreadableIds.contains(id)) return false;
    // The native index lists what MediaStore returns to this app right now;
    // photo_manager's per-id query is not usable without its permission.
    final native = _nativeIds;
    if (native != null && !hasAccess) return native.contains(id);
    return (presenceProbeForTesting ?? mediaExists)(id);
  }

  static const MethodChannel _mediaChannel = MethodChannel('easysave/media');

  /// How the current album index was built: `plugin` (photo_manager with its
  /// permission) or `native` (MediaStore through [_mediaChannel], used when
  /// photo_manager reports no access, e.g. in the overlay engine).
  String _lookupMethod = 'plugin';
  String get lookupMethod => _lookupMethod;

  /// Permission reported by the native side for the native index.
  String? _nativePermission;
  Set<String>? _nativeIds;
  int _nativeOwned = 0;

  /// Test seams for the platform calls; production leaves them null.
  @visibleForTesting
  Future<PermissionState> Function()? permissionReaderForTesting;
  @visibleForTesting
  Future<List<AssetEntity>> Function()? albumReaderForTesting;
  @visibleForTesting
  Future<bool> Function(String id)? presenceProbeForTesting;
  @visibleForTesting
  Future<Map<Object?, Object?>?> Function(List<String> albums)?
      nativeIndexReaderForTesting;

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

  /// Lower-case display name without extension -> asset. MediaStore titles
  /// carry their extension, so a lookup by base name needs this map.
  final Map<String, AssetEntity> _stemMap = {};

  void _indexStem(String baseName, AssetEntity asset) {
    final dot = baseName.lastIndexOf('.');
    if (dot > 0) _stemMap.putIfAbsent(baseName.substring(0, dot), () => asset);
  }
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

  /// AssetEntities this session already failed to resolve; never retried, so a
  /// stuck MediaStore look-up does not keep re-queueing the same id.
  final Set<String> _preloadMisses = {};

  /// Asynchronously retrieve AssetEntity by mediaId, querying MediaStore if not cached.
  Future<AssetEntity?> getAssetByIdAsync(String? mediaId) async {
    if (mediaId == null || mediaId.isEmpty) return null;
    if (_idMap.containsKey(mediaId)) return _idMap[mediaId];
    if (!hasAccess) return null;
    try {
      final asset = await LocalMedia.assetById(mediaId);
      if (asset != null) {
        _idMap[mediaId] = asset;
        if (asset.title != null && asset.title!.isNotEmpty) {
          _exactMap[asset.title!.toLowerCase()] = asset;
        }
        return asset;
      }
    } on MediaLoadTimeout {
      _preloadMisses.add(mediaId);
    } catch (_) {}
    return null;
  }

  /// Preload AssetEntities for known mediaIds without scanning entire album.
  ///
  /// Bounded: only [limit] ids are ever asked in one call, lookups share the
  /// lookup pool (4 slots) with other gallery reads, and ids that failed once
  /// are not retried this session. A stuck lookup blocks at most its own
  /// deadline instead of blocking every thumbnail forever.
  Future<void> preloadMediaIds(List<HistoryRecord> records, {int limit = 24}) async {
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return;
    }
    final idsToFetch = <String>[];
    for (final r in records) {
      for (final f in r.files) {
        final id = f.mediaId;
        if (id != null &&
            id.isNotEmpty &&
            !_idMap.containsKey(id) &&
            !_preloadMisses.contains(id) &&
            !idsToFetch.contains(id)) {
          idsToFetch.add(id);
        }
        if (idsToFetch.length >= limit) break;
      }
      if (idsToFetch.length >= limit) break;
    }
    if (idsToFetch.isEmpty) return;
    var changed = false;
    await Future.wait([
      for (final id in idsToFetch)
        () async {
          try {
            final asset = await LocalMedia.assetById(id);
            if (asset != null) {
              _idMap[id] = asset;
              changed = true;
              if (asset.title != null && asset.title!.isNotEmpty) {
                _exactMap[asset.title!.toLowerCase()] = asset;
              }
            } else {
              _preloadMisses.add(id);
            }
          } on MediaLoadTimeout {
            _preloadMisses.add(id);
          } catch (_) {
            _preloadMisses.add(id);
          }
        }(),
    ]);
    if (changed) notifyListeners();
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
      _stemMap.removeWhere((_, a) => a.id == id);
    }
    notifyListeners();
  }

  /// Check current permission state without prompting the user.
  Future<PermissionState> checkPermission() async {
    try {
      final permission = await (permissionReaderForTesting?.call() ??
          LocalMedia.permission());
      final changed = permission != _permission;
      _permission = permission;
      if (changed) notifyListeners();
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
  Future<PermissionState> requestPermission({bool scan = true}) async {
    try {
      _permission = await PhotoManager.requestPermissionExtend(requestOption: _defaultOption);
      notifyListeners();
      if (_permission.hasAccess && scan) {
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
      final testAlbum = albumReaderForTesting;
      if (testAlbum != null) {
        _replaceIndex(await testAlbum());
        _lookupMethod = 'plugin';
        _nativeIds = null;
        _scanned = true;
        return;
      }
      final settings = await AppSettings.load();
      final albumName = settings.albumName.trim().toLowerCase();
      // Every album the app has used, not just the current one: renaming the
      // album must not hide the files that were saved before the rename.
      final wanted = {
        for (final name in settings.effectiveAlbumNames) name.trim().toLowerCase(),
      };

      final paths = await LocalMedia.assetPaths(
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
      for (final asset in await fixedC2paAssets()) {
        if (seenIds.add(asset.id)) assetsToIndex.add(asset);
      }

      for (final p in paths) {
        if (p.isAll) continue;
        if (!wanted.contains(p.name.trim().toLowerCase())) continue;
        final count = await LocalMedia.assetCount(p);
        if (count <= 0) continue;
        final list = await LocalMedia.assetRange(p, 0, count);
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
        final count = await LocalMedia.assetCount(allAlbum);
        if (count > 0) {
          final list = await LocalMedia.assetRange(allAlbum, 0, count);
          for (final a in list) {
            if (seenIds.add(a.id)) assetsToIndex.add(a);
          }
        }
      }

      _replaceIndex(assetsToIndex);
      _lookupMethod = 'plugin';
      _nativeIds = null;
      _scanned = true;
    } catch (e) {
      debugPrint('GalleryLocatorService.scanAlbum error: $e');
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  void _replaceIndex(List<AssetEntity> assets) {
    _exactMap.clear();
    _stemMap.clear();
    _idMap.clear();
    _allAssets.clear();
    _relPathMap.clear();
    _xmpCache.clear();
    for (final asset in assets) {
      _idMap[asset.id] = asset;
      _allAssets.add(asset);
      final title = (asset.title ?? '').trim().toLowerCase();
      if (title.isNotEmpty) {
        _exactMap[title] = asset;
        // Strip directory path if title has any
        final baseName = title.split('/').last.split('\\').last;
        _exactMap[baseName] = asset;
        _indexStem(baseName, asset);
      }
    }
  }

  /// Index EasySave's albums through native MediaStore when photo_manager has
  /// no access (its permission query needs an Activity, so the overlay engine
  /// always sees notDetermined). Without read permission Android 10+ still
  /// returns the files this app wrote, so EasySave's own saves are found.
  Future<bool> _loadNativeIndex() async {
    try {
      final settings = await AppSettings.load();
      final albums = [
        for (final name in settings.effectiveAlbumNames)
          if (name.trim().isNotEmpty) name.trim(),
      ];
      final raw = await (nativeIndexReaderForTesting?.call(albums) ??
          _mediaChannel.invokeMethod<Map<Object?, Object?>>(
            'savedMediaIndex',
            {'albums': albums},
          ));
      if (raw == null) return false;
      final assets = <AssetEntity>[];
      var owned = 0;
      for (final item in (raw['items'] as List? ?? const []).whereType<Map>()) {
        final id = item['id']?.toString();
        if (id == null || id.isEmpty) continue;
        if (item['owned'] == true) owned++;
        assets.add(AssetEntity(
          id: id,
          typeInt: (item['type'] == 'video' ? AssetType.video : AssetType.image).index,
          width: (item['width'] as num?)?.toInt() ?? 0,
          height: (item['height'] as num?)?.toInt() ?? 0,
          title: item['title']?.toString(),
          relativePath: item['relativePath']?.toString(),
        ));
      }
      _replaceIndex(assets);
      for (final asset in assets) {
        _relPathMap[asset.id] = asset.relativePath;
      }
      _nativeIds = {for (final asset in assets) asset.id};
      _nativeOwned = owned;
      _nativePermission = raw['permission']?.toString() ?? 'unknown';
      _lookupMethod = 'native';
      _scanned = true;
      if (raw['error'] != null) {
        unawaited(DevLog.write('SavedLookup',
            'event=native_query_error error=${raw['error']} sdk=${raw['sdk']}'));
      }
      return true;
    } catch (e) {
      unawaited(DevLog.write('SavedLookup',
          'event=native_unavailable type=${e.runtimeType}'));
      return false;
    }
  }

  /// Make sure an album index exists: photo_manager when it has access,
  /// otherwise native MediaStore. [force] rebuilds it. Returns false when no
  /// index could be built.
  Future<bool> ensureIndexed({bool force = false}) async {
    if (!hasAccess) await checkPermission();
    if (hasAccess) {
      if (force || !_scanned || _lookupMethod == 'native') {
        await scanAlbum(force: true);
      }
      return true;
    }
    if (force || _lookupMethod != 'native' || _nativeIds == null) {
      return _loadNativeIndex();
    }
    return true;
  }

  /// Provenance of an album file from its header bytes and sidecar (never a
  /// full-file copy, which a large video would not survive on a full disk).
  Future<XmpProvenance?> readAlbumProvenance(AssetEntity asset) async {
    if (_xmpCache.containsKey(asset.id)) return _xmpCache[asset.id];
    final mime = asset.type == AssetType.video ? 'video/mp4' : 'image/jpeg';
    final bytes = await MediaHeaderService.readHeader(asset.id, mime);
    final prov = mergeProvenanceXml(MetadataService.readXmpXmlFromBytes(bytes),
        await readProvenanceSidecarXml(asset.id));
    _xmpCache[asset.id] = prov;
    return prov;
  }

  /// Exact album lookup by a file's base name (no extension). Unlike
  /// [locateAsset] this never fuzzy-matches, so it is safe to use as an
  /// idempotency guard: "is a file with this name already in the album?"
  AssetEntity? assetByBaseName(String baseName) {
    if (!hasAccess && _nativeIds == null) return null;
    final key = baseName.trim().toLowerCase();
    if (key.isEmpty) return null;
    return _exactMap[key] ?? _stemMap[key];
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
    _replaceIndex(assets ?? const []);
    if (relativePaths != null) {
      _relPathMap.addAll(relativePaths);
    }
    notifyListeners();
  }

  /// Testing hook to reset locator state.
  @visibleForTesting
  void resetForTesting() {
    nativeIndexReaderForTesting = null;
    _lookupMethod = 'plugin';
    _nativeIds = null;
    _nativePermission = null;
    _nativeOwned = 0;
    permissionReaderForTesting = null;
    albumReaderForTesting = null;
    presenceProbeForTesting = null;
    _scanned = false;
    _isScanning = false;
    _permission = PermissionState.notDetermined;
    _exactMap.clear();
    _stemMap.clear();
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
    int? expectedItemIndex,
  }) async {
    try {
      XmpProvenance? prov = _xmpCache[asset.id];
      if (!_xmpCache.containsKey(asset.id)) {
        final mime = asset.type == AssetType.video ? 'video/mp4' : 'image/jpeg';
        final bytes = await MediaHeaderService.readHeader(asset.id, mime);
        prov = mergeProvenanceXml(MetadataService.readXmpXmlFromBytes(bytes),
            await readProvenanceSidecarXml(asset.id));
        _xmpCache[asset.id] = prov;
      }

      // 只有无 XMP 的文件才允许仅凭文件名关联。
      if (prov == null) {
        return true;
      }
      if ((prov.itemIndex != null && expectedItemIndex != null && prov.itemIndex != expectedItemIndex) ||
          (prov.sourceId != null && prov.sourceId != expectedPostId) ||
          (prov.platform != null && expectedPlatform != null &&
              toSpecPlatform(prov.platform!) != toSpecPlatform(expectedPlatform))) return false;

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
          prov.sourceId == expectedPostId &&
          (expectedItemIndex == null || prov.itemIndex == expectedItemIndex)) {
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
      return false;
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
          cached = await LocalMedia.assetById(file.mediaId!);
          if (cached != null) {
            _idMap[file.mediaId!] = cached;
            if (cached.title != null && cached.title!.isNotEmpty) {
              _exactMap[cached.title!.toLowerCase()] = cached;
            }
          }
        } catch (_) {}
      }
      if (cached != null) {
        final exists = await isPresent(cached.id);
        if (exists) {
          final title = (cached.title ?? '').trim().toLowerCase();
          final baseName = title.split('/').last.split('\\').last;
          final targetName = file.filename.trim().toLowerCase();
          if (targetName.isEmpty ||
              title == targetName ||
              baseName == targetName ||
              _matchesDoubleExtension(baseName, targetName)) {
            if (await _verifyXmpConsistency(cached, expectedAssetId: file.assetId,
                expectedPlatform: platform, expectedPostId: postId,
                expectedItemIndex: file.itemIndex)) return cached;
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
            if (!await _verifyXmpConsistency(asset, expectedAssetId: file.assetId,
                expectedPlatform: platform, expectedPostId: postId,
                expectedItemIndex: file.itemIndex)) continue;
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
          expectedItemIndex: file.itemIndex,
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
        List<AssetEntity> orderedCandidates = const [];
        if (seqMatch != null) {
          final seq = seqMatch.group(1)!;
          final withSeq = pool.where((a) {
            final t = (a.title ?? '').toLowerCase();
            return t.contains('_$seq.') ||
                t.contains('-$seq.') ||
                t.contains(' $seq.');
          }).toList();
          if (withSeq.isNotEmpty) {
            orderedCandidates = withSeq;
          }
        }

        for (final candidate in orderedCandidates) {
          final isConsistent = await _verifyXmpConsistency(
            candidate,
            expectedAssetId: file.assetId,
            expectedPlatform: platform,
            expectedPostId: postId,
            expectedItemIndex: file.itemIndex,
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
      final asset = _idMap[file.mediaId]!;
      final name = (asset.title ?? '').trim().toLowerCase().split('/').last.split('\\').last;
      final target = file.filename.trim().toLowerCase();
      final prov = _xmpCache[asset.id];
      if ((target.isEmpty || name == target || _matchesDoubleExtension(name, target)) &&
          (prov?.itemIndex == null || prov?.itemIndex == file.itemIndex)) return asset;
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
            (prov.sourceId == postId && prov.itemIndex == file.itemIndex)) {
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

        return null;
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
          // Not being able to look at the album is not evidence that a file
          // disappeared. Never downgrade a row that was already confirmed: that
          // made the history hide (and later re-show) files the user had saved.
          updatedFiles.add(file);
        }
      }
    }

    if (changed && record.id != null) {
      final db = await HistoryDb.instance();
      final merged = await db.syncScannedFiles(record.id!, record.files, updatedFiles);
      record.files.clear();
      record.files.addAll(merged);
    }
  }

  /// Sync all records in the list against the scanned album.
  Future<void> syncAll(List<HistoryRecord> records) async {
    for (final record in records) {
      await syncRecord(record);
    }
  }

  /// Return the item indices of [post] that are already saved locally.
  ///
  /// [refreshAlbum] re-reads permission and rescans the used albums first. The
  /// overlay's background engine passes it: that engine never ran the
  /// foreground start-up permission check, and its album index can predate
  /// files the foreground saved since. The result is never cached; every
  /// caller decides again from the current history rows and album.
  Future<Set<int>> findDownloadedIndices(
    ParsedPost post, {
    bool refreshAlbum = false,
  }) async => (await findDownloadedAssets(post, refreshAlbum: refreshAlbum)).keys.toSet();

  /// Same lookup as [findDownloadedIndices], but keeps the album asset behind
  /// each saved index. The native selection panel needs the MediaStore id to
  /// open an already-saved image from the album instead of the network.
  Future<Map<int, AssetEntity>> findDownloadedAssets(
    ParsedPost post, {
    bool refreshAlbum = false,
  }) async {
    if (refreshAlbum) {
      await checkPermission();
      if (hasAccess) {
        await scanAlbum(force: true);
      } else {
        await _loadNativeIndex();
      }
    }
    final matched = await matchPostItems(post);
    final native = _lookupMethod == 'native';
    unawaited(DevLog.write(
      'SavedLookup',
      'engine=${HistoryDb.engine} method=$_lookupMethod '
          'permission=${native ? _nativePermission : _permission.name} '
          'pluginPermission=${_permission.name} '
          'scanned=${_scanned ? 1 : 0} refreshed=${refreshAlbum ? 1 : 0} '
          'albumAssets=${_allAssets.length}${native ? ' owned=$_nativeOwned' : ''} '
          'items=${post.items.length} saved=${matched.length}',
    ));
    return matched;
  }

  /// Locate the album asset behind each item of [post] (index -> asset) using
  /// the persisted history record first, then a postId + sequence scan.
  Future<Map<int, AssetEntity>> matchPostItems(ParsedPost post, {bool liveVideoOnly = false}) async {
    final result = <int, AssetEntity>{};
    try {
      // A secondary engine starts with an unknown permission state; without
      // this read every lookup below would silently report nothing saved.
      if (!hasAccess) await checkPermission();
      if (hasAccess && (!_scanned || _lookupMethod == 'native')) {
        await scanAlbum(force: _lookupMethod == 'native');
      } else if (!hasAccess && _lookupMethod != 'native') {
        await _loadNativeIndex();
      }
      final db = await HistoryDb.instance();
      final record = await db.getByPostId(post.id, platform: post.platform);
      if (record != null && !record.isDeleted && record.files.isNotEmpty) {
        final is1Based = record.files.every((f) => f.itemIndex > 0);
        for (final file in record.files) {
          final zeroBased = is1Based ? file.itemIndex - 1 : file.itemIndex;
          if (zeroBased < 0 || zeroBased >= post.items.length) continue;
          if (liveVideoOnly && (file.isImage || post.items[zeroBased].type != 'live')) continue;
          final asset = await locateAssetAsync(
            file,
            post.id,
            platform: record.platform,
          );
          if (asset != null) {
            final exists = await isPresent(asset.id);
            if (!exists) {
              evictMediaIds([asset.id]);
              continue;
            }
            final previous = result[zeroBased];
            final preferredType = liveVideoOnly || post.items[zeroBased].type == 'video'
                ? AssetType.video : AssetType.image;
            if (previous == null || (asset.type == preferredType && previous.type != preferredType)) {
              result[zeroBased] = asset;
            }
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
            if (liveVideoOnly && it.type != 'live') continue;
            final isImage = !liveVideoOnly && it.type != 'video';
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
              for (final candidate in matched) {
                if (result.values.any((a) => a.id == candidate.id)) continue;
                if (!await _verifyXmpConsistency(candidate, expectedPlatform: post.platform,
                    expectedPostId: post.id, expectedItemIndex: i + 1)) continue;
                final exists = await isPresent(candidate.id);
                if (exists) {
                  result[i] = candidate;
                  break;
                } else {
                  evictMediaIds([candidate.id]);
                }
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
        aiLabel: post.aiLabel?.text,
        aiLabelSource: post.aiLabel?.source,
        postUrl: post.url,
        fileCount: files.length,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([for (final it in post.items) it.toJson()]),
        files: files,
      ),
      restoreDeleted: restoreDeleted,
      userSave: restoreDeleted,
      source: 'associate-existing',
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
      final paths = await LocalMedia.assetPaths(
        type: RequestType.image,
        hasAll: false,
      );
      final counts = <String, int>{};
      for (final path in paths) {
        if (path.isAll) continue;
        final count = await LocalMedia.assetCount(path);
        counts.update(path.name, (n) => n + count, ifAbsent: () => count);
      }
      return [for (final entry in counts.entries) (name: entry.key, count: entry.value)];
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
      final paths = await LocalMedia.assetPaths(
        type: RequestType.image,
        hasAll: true,
      );
      for (final path in paths) {
        if (path.isAll) return await LocalMedia.assetCount(path);
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
    final fixed = await fixedC2paAssets();
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return fixed;
    }
    final wanted = {
      for (final name in albumNames)
        if (name.trim().isNotEmpty) name.trim().toLowerCase(),
    };
    if (wanted.isEmpty) return fixed;
    try {
      final paths = await LocalMedia.assetPaths(
        type: RequestType.common,
        hasAll: false,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
          videoOption: const FilterOption(needTitle: true),
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
      return unionMedia(assets, fixed);
    } catch (e) {
      debugPrint('assetsInAlbums error: $e');
      return fixed;
    }
  }

  /// Every media item on the device (explicit "全部相册" rebuild only).
  Future<List<AssetEntity>> allImages() async {
    final fixed = await fixedC2paAssets();
    if (!_permission.hasAccess) {
      await checkPermission();
      if (!_permission.hasAccess) return fixed;
    }
    try {
      final paths = await LocalMedia.assetPaths(
        type: RequestType.common,
        hasAll: true,
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
          videoOption: const FilterOption(needTitle: true),
        ),
      );
      for (final path in paths) {
        if (path.isAll) {
          final count = await LocalMedia.assetCount(path);
          if (count <= 0) return fixed;
          return unionMedia(await LocalMedia.assetRange(path, 0, count), fixed);
        }
      }
    } catch (e) {
      debugPrint('allImages error: $e');
    }
    return fixed;
  }
}
