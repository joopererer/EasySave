import 'package:photo_manager/photo_manager.dart';

import 'local_media.dart';
import 'media_load_gate.dart';

/// What a MediaStore lookup actually established.
///
/// [unknown] is not "missing": the lookup timed out, the plugin queue was
/// saturated or the platform refused the query. Callers must keep the local
/// path in that case - treating it as missing is what pushed history covers of
/// locally saved posts onto the network.
enum MediaExistence { present, absent, unknown }

/// Every positive result comes from a fresh MediaStore ID lookup, not the
/// album cache.
Future<MediaExistence> mediaExistence(
  String id, {
  Future<AssetEntity?> Function(String)? query,
}) async {
  try {
    final asset =
        query != null ? await query(id) : await LocalMedia.assetById(id);
    if (asset == null) return MediaExistence.absent;
    final exists = await LocalMedia.assetExists(asset);
    return switch (exists) {
      true => MediaExistence.present,
      false => MediaExistence.absent,
      null => MediaExistence.unknown,
    };
  } on MediaLoadTimeout {
    return MediaExistence.unknown;
  } on MediaLoadCancelled {
    return MediaExistence.unknown;
  } catch (_) {
    return MediaExistence.unknown;
  }
}

/// Boolean shorthand: only a confirmed lookup counts as present.
Future<bool> mediaExists(
  String id, {
  Future<AssetEntity?> Function(String)? query,
}) async =>
    await mediaExistence(id, query: query) == MediaExistence.present;