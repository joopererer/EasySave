// Link helpers: find a supported post URL inside arbitrary shared text.
// Pure Dart, unit-tested (extractLink/isSupportedLink); resolveShortLink
// needs network and is covered by widget-free manual testing.

import 'dart:io';
import 'tiktok_links.dart';

final _urlPattern = RegExp(
  r"https?://[^\s<>"
  "'，。！？；：）】”　]+",
);
const _trailingPunctuation = ".,!?;:)]}\"'，。！？；：）】”…";

/// Supported post hosts (full pages and short links).
bool isSupportedLink(String url) {
  if (isTiktokLink(url)) return true;
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return host == 'xiaohongshu.com' ||
      host.endsWith('.xiaohongshu.com') ||
      host == 'rednote.com' ||
      host.endsWith('.rednote.com') ||
      host == 'xhslink.com' ||
      host.endsWith('.xhslink.com') ||
      host == 'xhslink.cn' ||
      host.endsWith('.xhslink.cn') ||
      host == 'instagram.com' ||
      host.endsWith('.instagram.com') ||
      host == 'instagr.am' ||
      host.endsWith('.instagr.am') ||
      host == 'x.com' ||
      host.endsWith('.x.com') ||
      host == 'twitter.com' ||
      host.endsWith('.twitter.com') ||
      host == 't.co' ||
      host.endsWith('.t.co');
}


/// Extract the first supported post URL from free text (share sheets often
/// include surrounding copy). Returns null when there is none.
String? extractLink(String text) => extractLinks(text).firstOrNull;

/// Extract all supported post URLs from free text, in order, deduplicated.
/// Bounded by [limit] (default 9) so a pasted wall of text can't queue
/// an unbounded batch.
List<String> extractLinks(String text, {int limit = 9}) {
  final links = <String>[];
  for (final match in _urlPattern.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty &&
        _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (isSupportedLink(url) && !links.contains(url)) {
      links.add(url);
      if (links.length >= limit) break;
    }
  }
  return links;
}

/// True for YouTube watch / Shorts / youtu.be links. EasySave never parses
/// these (see roadmap v1.2): they are handed to Seal instead.
bool isYouTubeLink(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty || uri == null) return false;
  final isHost =
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtu.be' ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');
  if (!isHost) return false;
  if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
    return uri.pathSegments.isNotEmpty;
  }
  final path = uri.path.toLowerCase();
  if (path == '/watch') return uri.queryParameters.containsKey('v');
  if (path.startsWith('/shorts/')) return true;
  return false;
}

/// Extract the first YouTube URL from free text. Separate from extractLink
/// because YouTube links are not "supported" — they route to Seal.
String? extractYouTubeLink(String text) {
  for (final match in _urlPattern.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty &&
        _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (isYouTubeLink(url)) return url;
  }
  return null;
}

/// Resolve xhslink short links to the final page URL with plain HTTP
/// redirect following (no WebView involved, so in-page app-open schemes
/// can't hijack the navigation). Other URLs pass through untouched.
Future<String> resolveShortLink(String url) async {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  final isShort =
      host == 'xhslink.com' ||
      host.endsWith('.xhslink.com') ||
      host == 'xhslink.cn' ||
      host.endsWith('.xhslink.cn') ||
      host == 't.co' ||
      host.endsWith('.t.co');

  if (!isShort || uri == null) return url;
  final client = HttpClient();
  try {
    var current = uri;
    for (var i = 0; i < 5; i++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 10)',
      );
      final response = await request.close();
      await response.drain<void>();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) return current.toString();
      current = current.resolve(location);
      if (current.scheme != 'http' && current.scheme != 'https') {
        return current.toString();
      }
    }
    return current.toString();
  } finally {
    client.close(force: true);
  }
}
