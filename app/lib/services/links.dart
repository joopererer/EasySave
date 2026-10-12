// Link helpers: find a supported post URL inside arbitrary shared text.
// Pure Dart, unit-tested.

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
