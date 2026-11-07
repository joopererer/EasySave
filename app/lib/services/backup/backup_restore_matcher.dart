// Copyright 2026 EasySave. All rights reserved.
// Finds the album file behind each file of a restored backup post.
//
// Order (backup v2 rules): the file's own provenance (sourceId + itemIndex, or
// assetId), then the file name convention, then the stored mediaId hint, which
// counts only when the name and the size match too. Every album file is
// assigned at most once per restore, and a candidate whose provenance names
// another post is never accepted, so one post's file cannot be linked to
// another post. Files without a match stay "not on this device".

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';

import '../../metadata/url_normalizer.dart' show toSpecPlatform;
import '../export_names.dart';
import '../gallery_locator_service.dart';
import 'backup_model.dart';

/// The album as seen by a restore. Production uses [GalleryLocatorService].
abstract class RestoreAlbum {
  /// Build the album index; false when no index is available (no permission
  /// and no native bridge), in which case nothing may be matched.
  Future<bool> ensureIndexed();
  List<AssetEntity> get assets;
  AssetEntity? byId(String id);
  Future<XmpProvenance?> provenance(AssetEntity asset);
  Future<int?> size(AssetEntity asset);
}

class LocatorRestoreAlbum implements RestoreAlbum {
  LocatorRestoreAlbum([GalleryLocatorService? locator])
      : _locator = locator ?? GalleryLocatorService.instance;

  final GalleryLocatorService _locator;
  static const _channel = MethodChannel('easysave/media');

  @override
  Future<bool> ensureIndexed() => _locator.ensureIndexed(force: true);

  @override
  List<AssetEntity> get assets => _locator.getScannedAssets();

  @override
  AssetEntity? byId(String id) => _locator.getAssetById(id);

  @override
  Future<XmpProvenance?> provenance(AssetEntity asset) async {
    try {
      return await _locator.readAlbumProvenance(asset);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> size(AssetEntity asset) async {
    try {
      final size = await _channel.invokeMethod<num>('mediaSize', {
        'id': asset.id,
        'video': asset.type == AssetType.video,
      });
      return size?.toInt();
    } catch (_) {
      return null;
    }
  }
}

/// How a restored file was matched.
enum RestoreMatchVia { provenance, filename, mediaIdHint }

class RestoreMatch {
  const RestoreMatch(this.asset, this.via);
  final AssetEntity asset;
  final RestoreMatchVia via;
}

class BackupRestoreMatcher {
  BackupRestoreMatcher(this.album);

  final RestoreAlbum album;

  /// Album ids already linked during this restore.
  final Set<String> _used = {};

  bool _indexed = false;
  bool get indexed => _indexed;

  Future<bool> prepare() async {
    try {
      _indexed = await album.ensureIndexed();
    } catch (_) {
      _indexed = false;
    }
    return _indexed;
  }

  /// Link an album file already recorded locally, so it is not handed to
  /// another backup file.
  void reserve(String? mediaId) {
    if (mediaId != null && mediaId.isNotEmpty) _used.add(mediaId);
  }

  static String _stem(String name) {
    final base = name.trim().toLowerCase().split('/').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  bool _typeMatches(AssetEntity asset, BackupFile file) =>
      file.mediaType == 'video'
          ? asset.type == AssetType.video
          : asset.type == AssetType.image;

  static bool _samePost(XmpProvenance prov, BackupPost post) =>
      prov.sourceId == post.sourceId &&
      (prov.platform == null ||
          toSpecPlatform(prov.platform!) == toSpecPlatform(post.platform));

  /// Provenance proving this file: its assetId, or post + itemIndex.
  static bool _provesFile(XmpProvenance prov, BackupPost post, BackupFile file) {
    if (file.assetId != null && file.assetId!.isNotEmpty && prov.assetId == file.assetId) {
      return true;
    }
    return _samePost(prov, post) &&
        (prov.itemIndex == file.itemIndex ||
            (prov.itemIndex == null && post.files.length == 1));
  }

  /// Provenance that names another post or item rules a candidate out.
  static bool _contradicts(XmpProvenance? prov, BackupPost post, BackupFile file) {
    if (prov == null) return false;
    if (prov.sourceId != null && !_samePost(prov, post)) return true;
    return prov.itemIndex != null && prov.itemIndex != file.itemIndex;
  }

  Future<RestoreMatch?> match(BackupPost post, BackupFile file) async {
    if (!_indexed) return null;
    final sourceId = post.sourceId.trim().toLowerCase();
    final wantedName = file.filename.trim().toLowerCase();
    String? conventional;
    try {
      conventional = _stem(cleanMediaFilename(
        post.sourceId,
        file.itemIndex,
        file.mediaType == 'video' ? 'mp4' : 'jpg',
      ));
    } catch (_) {
      conventional = null;
    }
    final hint = file.mediaIdHint == null ? null : album.byId(file.mediaIdHint!);
    final candidates = <AssetEntity>[
      if (hint != null) hint,
      for (final asset in album.assets)
        if (asset.id != hint?.id &&
            ((sourceId.isNotEmpty && (asset.title ?? '').toLowerCase().contains(sourceId)) ||
                (wantedName.isNotEmpty && (asset.title ?? '').trim().toLowerCase() == wantedName)))
          asset,
    ].where((a) => !_used.contains(a.id) && _typeMatches(a, file)).toList();

    final provenances = <String, XmpProvenance?>{};
    Future<XmpProvenance?> provenanceOf(AssetEntity asset) async =>
        provenances.containsKey(asset.id)
            ? provenances[asset.id]
            : (provenances[asset.id] = await album.provenance(asset));

    // 1. The file's own provenance.
    for (final asset in candidates) {
      final prov = await provenanceOf(asset);
      if (prov != null && _provesFile(prov, post, file)) {
        return _take(asset, RestoreMatchVia.provenance);
      }
    }
    // 2. File name convention (backup name or `<sourceId>_<itemIndex>`).
    for (final asset in candidates) {
      final title = (asset.title ?? '').trim().toLowerCase();
      // A generic name (e.g. IMG_0001.jpg) proves nothing about the post: the
      // name must carry this post's sourceId.
      final named = (conventional != null && _stem(title) == conventional) ||
          (wantedName.isNotEmpty &&
              title == wantedName &&
              sourceId.isNotEmpty &&
              wantedName.contains(sourceId));
      if (!named || _contradicts(await provenanceOf(asset), post, file)) continue;
      return _take(asset, RestoreMatchVia.filename);
    }
    // 3. mediaId hint, verified by name and size.
    if (hint != null && candidates.contains(hint) && file.size != null) {
      final sameName = (hint.title ?? '').trim().toLowerCase() == wantedName;
      if (sameName &&
          !_contradicts(await provenanceOf(hint), post, file) &&
          await album.size(hint) == file.size) {
        return _take(hint, RestoreMatchVia.mediaIdHint);
      }
    }
    return null;
  }

  RestoreMatch _take(AssetEntity asset, RestoreMatchVia via) {
    _used.add(asset.id);
    return RestoreMatch(asset, via);
  }
}
