import 'package:photo_manager/photo_manager.dart';

/// Every positive result comes from a fresh MediaStore ID lookup, not the
/// album cache. Query failures are not evidence that a file exists.
Future<bool> mediaExists(String id, {Future<AssetEntity?> Function(String)? query}) async {
  try {
    final asset = await (query ?? AssetEntity.fromId)(id);
    return asset != null && await asset.exists;
  } catch (_) { return false; }
}
