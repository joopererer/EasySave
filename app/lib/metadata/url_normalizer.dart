// Copyright 2026 EasySave. All rights reserved.

import 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

import '../services/site_registry.dart';

export 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

/// Canonical URL used to compare stored and new links. Values written under an
/// older spec (e.g. a rednote.com canonical before provenance-spec 0.1.8) are
/// normalized again for the comparison only; stored values are never rewritten.
String canonicalForComparison(String url) {
  final trimmed = url.trim();
  try {
    return normalizeUrl(trimmed);
  } catch (_) {
    return trimmed;
  }
}

/// Whether two links name the same post under the current spec.
bool sameCanonicalUrl(String? left, String? right) =>
    left != null &&
    right != null &&
    left.trim().isNotEmpty &&
    canonicalForComparison(left) == canonicalForComparison(right);

/// Accept app IDs and provenance platform names, including disabled sites.
/// Unknown historical platforms keep their original identity.
String toSpecPlatform(String platform) =>
    (SiteRegistry.current.byId(platform) ?? SiteRegistry.builtinById(platform))
        ?.platform ??
    platform;

String toAppPlatform(String platform) =>
    SiteRegistry.current.canonicalId(platform);

/// Metadata Credit uses creditName rather than the UI display name.
String platformDisplayName(String platform) =>
    SiteRegistry.current.byId(platform)?.creditName ?? platform;
