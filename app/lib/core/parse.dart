// Platform dispatcher: picks the right pure parser from the page URL.
// In v1.3a+, parsing is handled by parser.js injected into the WebView.

import 'models.dart';

bool isXhsHost(String host) =>
    host == 'xiaohongshu.com' ||
    host.endsWith('.xiaohongshu.com') ||
    host == 'xhslink.com' ||
    host.endsWith('.xhslink.com') ||
    host == 'xhslink.cn' ||
    host.endsWith('.xhslink.cn');

bool isInstagramHost(String host) =>
    host == 'instagram.com' ||
    host.endsWith('.instagram.com') ||
    host == 'instagr.am' ||
    host.endsWith('.instagr.am');

bool isXHost(String host) =>
    host == 'x.com' ||
    host.endsWith('.x.com') ||
    host == 'twitter.com' ||
    host.endsWith('.twitter.com');

/// Parse a supported post page. Dart platform parsers were replaced by
/// the unified JS parser bundle in v1.3a.
ParseResult parse(String html, String pageUrl) {
  final host = Uri.tryParse(pageUrl)?.host.toLowerCase();
  if (host == null || host.isEmpty) {
    return ParseResult.err(
      ParseError(
        code: ParseErrorCode.unsupportedUrl,
        message: 'Cannot parse URL: $pageUrl',
      ),
    );
  }
  if (!isXhsHost(host) && !isInstagramHost(host) && !isXHost(host)) {
    return ParseResult.err(
      ParseError(
        code: ParseErrorCode.unsupportedUrl,
        message: 'Unsupported host: $host',
      ),
    );
  }
  return ParseResult.err(
    ParseError(
      code: ParseErrorCode.invalidPage,
      message: 'Dart platform parsers removed; use JS parser via ParseService',
    ),
  );
}
