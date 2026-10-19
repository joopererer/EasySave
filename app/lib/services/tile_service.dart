// Quick Settings tile helpers (Android). "Add to control center" is native on
// Android 13+ (system confirmation dialog); older versions fall back to manual
// instructions shown by the caller.

import 'package:flutter/services.dart';

abstract final class TileService {
  static const MethodChannel _channel = MethodChannel('easysave/tile');

  /// Returns true when the system confirmed the tile was added (or was already
  /// present) on Android 13+. Returns false on older versions / on failure so
  /// the caller can show manual instructions.
  static Future<bool> addTile() async {
    try {
      return await _channel.invokeMethod<bool>('addTile') ?? false;
    } catch (_) {
      return false;
    }
  }
}
