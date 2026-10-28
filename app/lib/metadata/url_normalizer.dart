// Copyright 2026 EasySave. All rights reserved.

export 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

/// Primary canonical mapping from internal app identifiers to spec platform names.
/// See SPEC §2: prov:platform must be "xiaohongshu", "instagram", or "x".
const internalPlatformToSpec = <String, String>{
  'xhs': 'xiaohongshu',
  'instagram': 'instagram',
  'x': 'x',
  'tiktok': 'tiktok',
};

/// Map of platform identifiers to spec-compliant names.
/// Automatically includes idempotent mappings (spec -> spec).
final Map<String, String> appPlatformToSpecPlatform = {
  ...internalPlatformToSpec,
  for (final spec in internalPlatformToSpec.values) spec: spec,
};

/// Returns the spec-compliant platform name for an app internal identifier.
String toSpecPlatform(String platform) {
  return appPlatformToSpecPlatform[platform] ?? platform;
}

/// Map of spec-compliant platform names to internal app identifiers.
/// Derived automatically by inverting [internalPlatformToSpec].
final Map<String, String> specPlatformToAppPlatform = {
  for (final entry in internalPlatformToSpec.entries) entry.value: entry.key,
  for (final internal in internalPlatformToSpec.keys) internal: internal,
};

/// Returns the app internal identifier for a spec platform name.
String toAppPlatform(String platform) {
  return specPlatformToAppPlatform[platform] ?? platform;
}

/// Platform display names for photoshop:Credit field.
/// Maps app internal identifiers to localized display names.
/// Also accepts spec platform names (xiaohongshu, instagram, x) as input.
const appPlatformToDisplayName = {
  'xhs': '小红书',
  'xiaohongshu': '小红书',
  'instagram': 'Instagram',
  'x': 'X',
  'tiktok': 'TikTok',
};

/// Returns the localized display name for a platform.
/// Accepts both app internal identifiers (xhs, instagram, x) and 
/// spec platform names (xiaohongshu, instagram, x).
String platformDisplayName(String platform) {
  return appPlatformToDisplayName[platform] ?? platform;
}
