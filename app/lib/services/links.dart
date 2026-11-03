// Link helpers: find a supported post URL inside arbitrary shared text.
// Pure Dart, unit-tested (extractLink/isSupportedLink); resolveShortLink
// needs network and is covered by widget-free manual testing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/dev_log.dart';
import 'site_registry.dart';

String parsePathCategory(Uri? uri) {
  final path = uri?.path.toLowerCase() ?? '';
  if (RegExp(r'^/explore(?:/|$)').hasMatch(path)) return 'explore';
  if (RegExp(r'^/discovery/item(?:/|$)').hasMatch(path)) return 'discovery/item';
  if (path.contains('404')) return '404';
  if (path.contains('login')) return 'login';
  if (path.contains('captcha') || path.contains('verify')) return 'captcha';
  return 'other';
}

String terminalPathCategory(Uri uri) {
  if (uri.path.isEmpty || uri.path == '/' ||
      RegExp(r'^/explore/?$', caseSensitive: false).hasMatch(uri.path)) {
    return 'home';
  }
  return parsePathCategory(uri);
}

String shortLinkHtmlKind(String contentType, String body) {
  if (!contentType.toLowerCase().contains('html')) return 'not_html';
  final meta = RegExp(r'<meta\b[^>]*http-equiv\s*=\s*["\x27]?refresh\b', caseSensitive: false).hasMatch(body);
  final js = RegExp(r'(?:window\.)?location(?:\.href|\.replace|\.assign)?\s*[=(]', caseSensitive: false).hasMatch(body);
  return meta && js ? 'both' : meta ? 'meta' : js ? 'js' : 'none';
}

final _candidatePattern = RegExp(
  r"https?://[^\s<>"
  "'，。！？；：）】”　]+|(?<![a-zA-Z0-9_@./:-])(?:[a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}(?:[/？?#][^\\s<>"
  "'，。！？；：）】”　]*)?",
  caseSensitive: false,
);

String normalizeSupportedLink(String input) {
  final value = input.trim();
  if (value.contains('://')) return value;
  final candidate = 'https://$value';
  return _isSupportedAbsolute(candidate) ? candidate : input;
}

const _trailingPunctuation = ".,!?;:)]}\"'，。！？；：）】”…";

/// Supported post hosts (full pages and short links).
bool isSupportedLink(String url) =>
    _isSupportedAbsolute(normalizeSupportedLink(url));

bool _isSupportedAbsolute(String url) =>
    SiteRegistry.current.match(url) != null;

/// Extract the first supported post URL from free text (share sheets often
/// include surrounding copy). Returns null when there is none.
String? extractLink(String text) => extractLinks(text).firstOrNull;

/// Extract all supported post URLs from free text, in order, deduplicated.
/// Bounded by [limit] (default 9) so a pasted wall of text can't queue
/// an unbounded batch.
List<String> extractLinks(String text, {int limit = 9}) {
  final links = <String>[];
  for (final match in _candidatePattern.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty &&
        _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    url = normalizeSupportedLink(url);
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
  if (host.isEmpty ||
      uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
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
  if (path == '/watch') return (uri.queryParameters['v'] ?? '').isNotEmpty;
  if (RegExp(r'^/shorts/[^/]+/?$').hasMatch(path)) return true;
  return false;
}

/// Extract the first YouTube URL from free text. Separate from extractLink
/// because YouTube links are not "supported" — they route to Seal.
String? extractYouTubeLink(String text) {
  for (final match in _candidatePattern.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty &&
        _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.contains('://')) url = 'https://$url';
    if (isYouTubeLink(url)) return url;
  }
  return null;
}

/// All foreground entrances check the local external policy before the site registry.
Future<bool> routeExternalText(
  String text, {
  required Future<void> Function(String) present,
}) async {
  final url = extractYouTubeLink(text);
  if (url == null) return false;
  await present(url);
  return true;
}

/// Resolve declared short links to the final page URL with plain HTTP
/// redirect following (no WebView involved, so in-page app-open schemes
/// can't hijack the navigation). Other URLs pass through untouched.
Future<String> resolveShortLink(
  String url, {
  bool forHistoryLookup = false,
  Future<String?> Function(Uri)? readRedirect,
  Duration? timeout,
}) async {
  final uri = Uri.tryParse(url);
  final site = SiteRegistry.current.match(url);
  final rule = uri == null ? null : site?.shortLink(uri);
  if (uri == null || rule == null) return url;
  final strategy = forHistoryLookup
      ? (rule['historyStrategy'] ?? rule['strategy'])
      : rule['strategy'];
  if (strategy != 'http') return url;
  final client = HttpClient();
  final watch = Stopwatch()..start();
  final budget = forHistoryLookup ? const Duration(seconds: 3) : timeout;
  Future<T> bounded<T>(Future<T> work) {
    if (budget == null) return work;
    final remaining = budget.inMilliseconds - watch.elapsedMilliseconds;
    return work.timeout(
      Duration(milliseconds: remaining.clamp(1, budget.inMilliseconds)),
    );
  }

  if (budget != null) client.connectionTimeout = budget;
  try {
    var current = uri;
    for (var i = 0; i < (rule['maxRedirects'] as int); i++) {
      if (SiteRegistry.current
              .match(current.toString(), includeDisabled: true)
              ?.id !=
          site?.id) {
        final category = terminalPathCategory(current);
        final terminal = (site?.terminalPages ?? const [])
            .whereType<Map>().any((rule) => rule['category'] == category);
        if (site != null && site.hasHost(current.host) && terminal) {
          return current.toString();
        }
        throw const FormatException('短链跳转目标不受支持');
      }
      String? location;
      if (readRedirect != null) {
        location = await bounded(readRedirect(current));
      } else {
        final request = await bounded(client.getUrl(current));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 10)',
        );
        final response = await bounded(request.close());
        location = response.headers.value(HttpHeaders.locationHeader);
        final bytes = <int>[];
        await bounded(() async {
          await for (final chunk in response) {
            final remaining = 32768 - bytes.length;
            if (remaining <= 0) break;
            bytes.addAll(chunk.take(remaining));
            if (bytes.length >= 32768) break;
          }
        }());
        final next = location == null ? null : current.resolve(location);
        final host = next?.host.toLowerCase() ?? '';
        final safeHost = RegExp(r'^[a-z0-9.:-]{1,253}$').hasMatch(host) ? host : '-';
        final kind = shortLinkHtmlKind(
          response.headers.contentType?.mimeType ?? '',
          utf8.decode(bytes, allowMalformed: true),
        );
        unawaited(DevLog.write('ShortLink',
          'status=${response.statusCode} location=${location == null ? 0 : 1} host=$safeHost path=${parsePathCategory(next)} hop=${i + 1} html=$kind'));
      }
      if (location == null) return current.toString();
      current = current.resolve(location);
      if (current.scheme != 'http' && current.scheme != 'https') {
        throw const FormatException('短链跳转目标不受支持');
      }
    }
    return current.toString();
  } finally {
    client.close(force: true);
  }
}
