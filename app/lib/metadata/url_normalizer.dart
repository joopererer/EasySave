// Copyright 2026 EasySave. All rights reserved.
// URL normalization for provenance metadata.
// Implements the normalization rules in docs/provenance-spec/SPEC.md §3.

/// Normalizes a URL for provenance metadata according to SPEC §3.
/// - Removes tracking parameters
/// - Removes URL fragments
/// - Lowercases scheme and hostname
/// - Platform-specific normalization:
///   - xiaohongshu: https://www.xiaohongshu.com/explore/{noteId}
///   - instagram: https://www.instagram.com/p/{shortcode}/
///   - x: https://x.com/i/status/{tweetId}
String normalizeUrl(String url) {
  final uri = Uri.parse(url);
  
  // Lowercase scheme and hostname
  final normalizedScheme = uri.scheme.toLowerCase();
  final normalizedHost = uri.host.toLowerCase();
  
  // Platform-specific normalization
  if (normalizedHost == 'www.xiaohongshu.com' || normalizedHost == 'xiaohongshu.com') {
    return _normalizeXhs(uri);
  }
  
  if (normalizedHost == 'www.instagram.com' || normalizedHost == 'instagram.com') {
    return _normalizeInstagram(uri);
  }
  
  if (normalizedHost == 'x.com' || normalizedHost == 'twitter.com') {
    return _normalizeX(uri);
  }
  
  // Generic normalization
  final filteredParams = <String, String>{};
  uri.queryParameters.forEach((key, value) {
    if (!_isTrackingParam(key.toLowerCase())) {
      filteredParams[key] = value;
    }
  });
  
  return Uri(
    scheme: normalizedScheme,
    host: normalizedHost,
    path: uri.path,
    queryParameters: filteredParams.isEmpty ? null : filteredParams,
  ).toString();
}

String _normalizeXhs(Uri uri) {
  // Extract noteId from /discovery/item/{noteId} or /explore/{noteId}
  final pathSegments = uri.pathSegments;
  String? noteId;
  
  if (pathSegments.length >= 3 && pathSegments[0] == 'discovery' && pathSegments[1] == 'item') {
    noteId = pathSegments[2];
  } else if (pathSegments.length >= 2 && pathSegments[0] == 'explore') {
    noteId = pathSegments[1];
  }
  
  if (noteId == null || noteId.isEmpty) {
    return uri.toString(); // Fallback if pattern doesn't match
  }
  
  return 'https://www.xiaohongshu.com/explore/$noteId';
}

String _normalizeInstagram(Uri uri) {
  // Extract shortcode from /p/{shortcode}/ or /reel/{shortcode}/
  final pathSegments = uri.pathSegments;
  String? shortcode;
  
  if (pathSegments.length >= 2) {
    if (pathSegments[0] == 'p' || pathSegments[0] == 'reel') {
      shortcode = pathSegments[1];
    }
  }
  
  if (shortcode == null || shortcode.isEmpty) {
    return uri.toString(); // Fallback
  }
  
  return 'https://www.instagram.com/p/$shortcode/';
}

String _normalizeX(Uri uri) {
  // Extract tweetId from /{username}/status/{tweetId} or /i/status/{tweetId}
  final pathSegments = uri.pathSegments;
  String? tweetId;
  
  if (pathSegments.length >= 3 && pathSegments[1] == 'status') {
    tweetId = pathSegments[2];
  } else if (pathSegments.length >= 3 && pathSegments[0] == 'i' && pathSegments[1] == 'status') {
    tweetId = pathSegments[2];
  }
  
  if (tweetId == null || tweetId.isEmpty) {
    return uri.toString(); // Fallback
  }
  
  return 'https://x.com/i/status/$tweetId';
}

bool _isTrackingParam(String key) {
  const trackingParams = {
    'utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term',
    'fbclid', 'gclid', 'igsh', 'igshid', 'si', 'spm', 
    'share_', 'shareredid', 'xsec_token', 'xsec_source', 
    'apptime', 'author_share', 'xhsshare', 'track_code', 
    'app_platform', 'app_version', 'ignoreengage', 'dlrf', 'xtok', 'img_index',
    'usp', // Google Drive sharing param
  };
  
  final lowerKey = key.toLowerCase();
  
  // Exact match
  if (trackingParams.contains(lowerKey)) {
    return true;
  }
  
  // Prefix match for share_* params
  if (lowerKey.startsWith('share_') || lowerKey.startsWith('utm_')) {
    return true;
  }
  
  return false;
}
