// Every photo_manager call the app makes goes through here.
//
// Why: photo_manager runs each call on a fixed 8-thread executor with an
// unbounded FIFO queue. Nothing in the app had a deadline, so one call that
// never returns (a whole-file copy of a large video, a full-size original read)
// parked a thread forever and every thumbnail behind it waited - across posts,
// pages and engines - until the process restarted.
//
// [LocalMedia] adds a deadline and a [MediaLoad] log line to each call and
// routes it into the pool of its request class (see media_load_gate.dart).
//
// Which APIs can copy a whole file (audit, requirement 5):
//   * getFullFile (`AssetEntity.file`, `originFile`, `loadFile`)
//       Android 10 (SDK 29) with scoped storage: ScopedCache copies the whole
//       file into the app cache before returning a path. Android 11+: returns
//       the MediaStore path, no copy.
//   * getOriginBytes (`originBytes`)
//       SDK <= 29 falls back to originFile (copy), SDK > 29 streams the whole
//       file into memory.
//   * getMediaUrl (`AssetEntity.getMediaUrl`)
//       Returns a content:// URI; no copy, no bytes. Used for video playback.
//   * thumbnailDataWithSize -> Glide; decodes a thumbnail, never the original.
//   * readMediaHeader (native `easysave/media`): reads the header bytes only.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'media_header_service.dart';
import 'media_load_gate.dart';

/// The photo_manager/MediaStore surface used by [LocalMedia]. Tests replace
/// [LocalMedia.impl] to count calls and to hang individual ones.
abstract class LocalMediaApi {
  Future<PermissionState> permission(RequestType type);

  Future<List<AssetPathEntity>> assetPaths({
    required RequestType type,
    required bool hasAll,
    FilterOptionGroup? filter,
  });

  Future<int> assetCount(AssetPathEntity path);

  Future<List<AssetEntity>> assetRange(AssetPathEntity path, int start, int end);

  Future<AssetEntity?> assetById(String id);

  Future<bool> assetExists(AssetEntity asset);

  Future<Uint8List?> thumbnail(AssetEntity asset, ThumbnailSize size);

  /// Path of the asset. On Android 10 this copies the whole file.
  Future<File?> file(AssetEntity asset, {required bool isOrigin});

  /// content:// URI (or file path) for a player; never copies bytes.
  Future<String?> mediaUri(AssetEntity asset);

  /// Assets carrying C2PA metadata, if the build has such a source.
  Future<List<AssetEntity>> c2paAssets();
}

class PhotoManagerLocalMediaApi implements LocalMediaApi {
  const PhotoManagerLocalMediaApi();

  static const _option = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  @override
  Future<PermissionState> permission(RequestType type) =>
      PhotoManager.getPermissionState(requestOption: _option);

  @override
  Future<List<AssetPathEntity>> assetPaths({
    required RequestType type,
    required bool hasAll,
    FilterOptionGroup? filter,
  }) => PhotoManager.getAssetPathList(
    type: type,
    hasAll: hasAll,
    filterOption: filter,
  );

  @override
  Future<int> assetCount(AssetPathEntity path) => path.assetCountAsync;

  @override
  Future<List<AssetEntity>> assetRange(
    AssetPathEntity path,
    int start,
    int end,
  ) => path.getAssetListRange(start: start, end: end);

  @override
  Future<AssetEntity?> assetById(String id) => AssetEntity.fromId(id);

  @override
  Future<bool> assetExists(AssetEntity asset) => asset.exists;

  @override
  Future<Uint8List?> thumbnail(AssetEntity asset, ThumbnailSize size) =>
      asset.thumbnailDataWithSize(size);

  @override
  Future<File?> file(AssetEntity asset, {required bool isOrigin}) =>
      asset.getFile(isOrigin: isOrigin);

  @override
  Future<String?> mediaUri(AssetEntity asset) => asset.getMediaUrl();

  @override
  Future<List<AssetEntity>> c2paAssets() async => const [];
}

/// Thin, logged, deadlined wrappers. Nothing calls photo_manager directly.
abstract final class LocalMedia {
  static LocalMediaApi impl = const PhotoManagerLocalMediaApi();

  @visibleForTesting
  static void resetForTesting() => impl = const PhotoManagerLocalMediaApi();

  static Future<PermissionState> permission({MediaLoadScope? scope}) =>
      MediaLoadGate.run(
        kind: MediaLoadKind.lookup,
        id: 'permission',
        source: 'getPermissionState',
        timeout: const Duration(seconds: 10),
        scope: scope,
        action: () => impl.permission(RequestType.common),
      );

  static Future<List<AssetPathEntity>> assetPaths({
    RequestType type = RequestType.common,
    bool hasAll = true,
    FilterOptionGroup? filterOption,
    MediaLoadScope? scope,
  }) => MediaLoadGate.run(
    kind: MediaLoadKind.lookup,
    id: 'albums',
    source: 'getAssetPathList',
    timeout: const Duration(seconds: 20),
    scope: scope,
    action: () => impl.assetPaths(
      type: type,
      hasAll: hasAll,
      filter: filterOption,
    ),
  );

  static Future<int> assetCount(AssetPathEntity path, {MediaLoadScope? scope}) =>
      MediaLoadGate.run(
        kind: MediaLoadKind.lookup,
        id: path.id,
        source: 'assetCountAsync',
        timeout: const Duration(seconds: 10),
        scope: scope,
        action: () => impl.assetCount(path),
      );

  static Future<List<AssetEntity>> assetRange(
    AssetPathEntity path,
    int start,
    int end, {
    MediaLoadScope? scope,
    bool background = false,
  }) => MediaLoadGate.run(
    kind: MediaLoadKind.lookup,
    id: '${path.id}:$start-$end',
    source: 'getAssetListRange',
    timeout: const Duration(seconds: 20),
    scope: scope,
    background: background,
    action: () => impl.assetRange(path, start, end),
  );

  static Future<AssetEntity?> assetById(
    String id, {
    MediaLoadScope? scope,
    bool background = false,
  }) => MediaLoadGate.run(
    kind: MediaLoadKind.lookup,
    id: id,
    source: 'fromId',
    scope: scope,
    background: background,
    action: () => impl.assetById(id),
  );

  /// `null` means the lookup did not settle: not evidence of a deleted file.
  static Future<bool?> assetExists(
    AssetEntity asset, {
    MediaLoadScope? scope,
  }) async {
    try {
      return await MediaLoadGate.run(
        kind: MediaLoadKind.lookup,
        id: asset.id,
        source: 'exists',
        scope: scope,
        action: () => impl.assetExists(asset),
      );
    } on MediaLoadTimeout {
      return null;
    } on MediaLoadCancelled {
      return null;
    }
  }

  static Future<Uint8List?> thumbnail(
    AssetEntity asset,
    ThumbnailSize size, {
    MediaLoadScope? scope,
    bool cover = true,
    bool background = false,
  }) => MediaLoadGate.run(
    kind: cover ? MediaLoadKind.cover : MediaLoadKind.thumb,
    id: asset.id,
    source: 'thumbnailDataWithSize',
    scope: scope,
    background: background,
    extra: 'size=${size.width}x${size.height}',
    action: () => impl.thumbnail(asset, size),
  );

  /// The full-size original as bytes, deadlined from the file size when the
  /// MediaStore can report it.
  static Future<Uint8List?> originalBytes(
    AssetEntity asset, {
    MediaLoadScope? scope,
    int? knownBytes,
  }) async {
    final bytes = knownBytes ?? await fileSize(asset);
    return MediaLoadGate.run(
      kind: MediaLoadKind.original,
      id: asset.id,
      source: 'loadFile+readAsBytes',
      timeout: MediaLoadGate.limits.forBytes(bytes),
      scope: scope,
      extra: 'bytes=${bytes ?? -1}',
      action: () async {
        final file = await impl.file(asset, isOrigin: true);
        if (file == null) return null;
        return file.readAsBytes();
      },
    );
  }

  /// File path of an asset. Only for actions that genuinely need a path
  /// (sharing, metadata rewriting) - never for playback.
  static Future<File?> file(
    AssetEntity asset, {
    bool isOrigin = false,
    MediaLoadScope? scope,
    int? knownBytes,
  }) async {
    final bytes = knownBytes ?? await fileSize(asset);
    return MediaLoadGate.run(
      kind: MediaLoadKind.original,
      id: asset.id,
      source: 'getFullFile',
      timeout: MediaLoadGate.limits.forBytes(bytes),
      scope: scope,
      // Android 10 copies the whole file here; the log names it.
      extra: 'origin=${isOrigin ? 1 : 0} wholeFileCopy=${_android ? 1 : 0}',
      action: () => impl.file(asset, isOrigin: isOrigin),
    );
  }

  /// A content:// URI the player can stream: no copy, no bytes.
  static Future<String?> mediaUri(
    AssetEntity asset, {
    MediaLoadScope? scope,
  }) => MediaLoadGate.run(
    kind: MediaLoadKind.lookup,
    id: asset.id,
    source: 'getMediaUrl',
    scope: scope,
    action: () => impl.mediaUri(asset),
  );

  /// MediaStore SIZE in bytes (native channel, no file read), best effort.
  static Future<int?> fileSize(AssetEntity asset) async {
    try {
      return await MediaLoadGate.run(
        kind: MediaLoadKind.lookup,
        id: asset.id,
        source: 'mediaSize',
        timeout: const Duration(seconds: 2),
        action: () => MediaHeaderService.fileSize(
          asset.id,
          video: asset.type == AssetType.video,
        ),
      );
    } on MediaLoadTimeout {
      return null;
    } on MediaLoadCancelled {
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}