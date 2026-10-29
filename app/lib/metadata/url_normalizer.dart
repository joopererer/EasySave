// Copyright 2026 EasySave. All rights reserved.

import '../services/site_registry.dart';

export 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

/// Accept app IDs and provenance platform names, including disabled sites.
/// Unknown historical platforms keep their original identity.
String toSpecPlatform(String platform) =>
    SiteRegistry.current.byId(platform)?.platform ?? platform;

String toAppPlatform(String platform) =>
    SiteRegistry.current.byId(platform)?.id ?? platform;

/// Metadata Credit uses creditName rather than the UI display name.
String platformDisplayName(String platform) =>
    SiteRegistry.current.byId(platform)?.creditName ?? platform;
