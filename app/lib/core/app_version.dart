// Copyright 2026 EasySave. All rights reserved.
import 'package:package_info_plus/package_info_plus.dart';

/// Centralized app version provider.
class AppVersion {
  static const String defaultVersion = '1.8.2';
  static String? _cachedVersion;

  /// Test override for version string.
  static String? versionOverride;

  /// Returns the current app version from PackageInfo, cached after first call.
  static Future<String> getVersion() async {
    if (versionOverride != null) return versionOverride!;
    if (_cachedVersion != null) return _cachedVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedVersion = info.version;
      return info.version;
    } catch (_) {
      return defaultVersion;
    }
  }

  /// Synchronous version getter (falls back to defaultVersion if not yet cached).
  static String get currentVersion => versionOverride ?? _cachedVersion ?? defaultVersion;

  /// Format required by provenance-spec for prov:capturedBy.
  static String get capturedBy => 'EasySave/$currentVersion';
}
