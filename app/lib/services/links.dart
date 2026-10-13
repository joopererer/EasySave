// Link helpers: find a supported post URL inside arbitrary shared text.
// Pure Dart, unit-tested (extractLink/isSupportedLink); resolveShortLink
// needs network and is covered by widget-free manual testing.

import 'dart:io';

final _urlPattern = RegExp(r"https?://[^\s<>""'，。！？；：）】”　]+");
const _trailingPunctuation = ".,!?;:)]}\"'，。！？；：）】”…";

/// Supported post hosts (full pages and short links).
bool isSupportedLink(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return host == 'xiaohongshu.com' ||
      host.endsWith('.xiaohongshu.com') ||
      host == 'xhslink.com' ||
      host.endsWith('.xhslink.com') ||
      host == 'xhslink.cn' ||
      host.endsWith('.xhslink.cn') ||
      host == 'instagram.com' ||
      host.endsWith('.instagram.com') ||
      host == 'instagr.am' ||
      host.endsWith('.instagr.am');
}

/// Extract the first supported post URL from free text (share sheets often
/// include surrounding copy). Returns null when there is none.
String? extractLink(String text) {
  for (final match in _urlPattern.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty && _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (isSupportedLink(url)) return url;
  }
  return null;
}

/// Resolve xhslink short links to the final page URL with plain HTTP
/// redirect following (no WebView involved, so in-page app-open schemes
/// can't hijack the navigation). Other URLs pass through untouched.
Future<String> resolveShortLink(String url) async {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  final isShort = host == 'xhslink.com' ||
      host.endsWith('.xhslink.com') ||
      host == 'xhslink.cn' ||
      host.endsWith('.xhslink.cn');
  if (!isShort || uri == null) return url;
  final client = HttpClient();
  try {
    var current = uri;
    for (var i = 0; i < 5; i++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 10)');
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
