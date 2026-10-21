// Pure decisions behind the parse tab's clipboard prompt and stale-input
// handling. Kept free of Flutter / database imports so they are unit-tested.

import 'links.dart';

/// A history entry reduced to what link matching needs.
typedef KnownPost = ({String postUrl, String postId});

/// Host + path without "www." and trailing slashes; query and fragment are
/// ignored so tracking parameters never defeat the comparison.
String linkKey(String url) {
  try {
    final uri = Uri.parse(url.trim());
    final host = uri.host.replaceFirst('www.', '');
    return '$host${uri.path}'.replaceAll(RegExp(r'/+$'), '');
  } catch (_) {
    return url.trim();
  }
}

/// Best-effort post identity for a link: the XHS 24-hex note id, an
/// Instagram shortcode or an X status id.
String? postIdOfUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final hex = RegExp(r'[0-9a-fA-F]{24}').firstMatch(uri.path)?.group(0);
  if (hex != null) return hex.toLowerCase();
  final segs = uri.pathSegments;
  for (var i = 0; i + 1 < segs.length; i++) {
    final s = segs[i];
    if (s == 'p' || s == 'reel' || s == 'tv' || s == 'status') {
      return segs[i + 1].toLowerCase();
    }
  }
  return null;
}

/// True when [link] matches a history entry by canonical url or post id.
/// [resolvedUrl] is the redirect target of a short link (optional); it lets
/// an xhslink match the record stored under its canonical url.
bool isLinkKnown(
  String link,
  Iterable<KnownPost> records, {
  String? resolvedUrl,
}) {
  final key = linkKey(link);
  if (records.any((r) => linkKey(r.postUrl) == key)) return true;
  final id =
      postIdOfUrl(link) ??
      (resolvedUrl == null ? null : postIdOfUrl(resolvedUrl));
  if (id == null) return false;
  return records.any(
    (r) => r.postId.toLowerCase() == id || postIdOfUrl(r.postUrl) == id,
  );
}

/// True when the input box only holds supported links that are all already in
/// history — leftovers of a previous session that must not be re-parsed and
/// should be cleared. Unknown text (a link being typed or not yet downloaded)
/// is never stale.
bool inputIsStale(String inputText, bool Function(String link) isKnown) {
  final links = extractLinks(inputText);
  return links.isNotEmpty && links.every(isKnown);
}

/// The key under which the clipboard prompt remembers a text, so the prompt
/// is not shown twice for it. Must match the keys used by the parse page.
String? clipboardKeyOf(String text) {
  final yt = extractYouTubeLink(text);
  if (yt != null) return yt;
  final links = extractLinks(text);
  if (links.isEmpty) return null;
  if (links.length > 1) return 'batch:${links.join('|')}';
  return links.single;
}
