import 'package:provenance_dart/provenance_dart.dart';

bool isTiktokHost(String host) => const {
  'tiktok.com', 'www.tiktok.com', 'm.tiktok.com',
  'vm.tiktok.com', 'vt.tiktok.com',
}.contains(host.toLowerCase());

bool isTiktokLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !['http', 'https'].contains(uri.scheme) ||
      !isTiktokHost(uri.host)) return false;
  if (uri.host == 'vm.tiktok.com' || uri.host == 'vt.tiktok.com') {
    return RegExp(r'^/[^/]+/?$').hasMatch(uri.path);
  }
  return extractTiktokPostId(url) != null;
}

/// A short URL must be expanded by WebView before calling this helper.
String? canonicalTiktokUrl(String url) {
  if (!isTiktokLink(url) || extractTiktokPostId(url) == null) return null;
  return normalizeUrl(url);
}
