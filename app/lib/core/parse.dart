// Platform dispatcher: picks the right pure parser from the page URL.
// Mirrors extension/src/index.ts.

import 'instagram.dart';
import 'models.dart';
import 'xhs.dart';

bool _isXhsHost(String host) =>
    host == 'xiaohongshu.com' ||
    host.endsWith('.xiaohongshu.com') ||
    host == 'xhslink.com' ||
    host.endsWith('.xhslink.com') ||
    host == 'xhslink.cn' ||
    host.endsWith('.xhslink.cn');

bool _isInstagramHost(String host) =>
    host == 'instagram.com' ||
    host.endsWith('.instagram.com') ||
    host == 'instagr.am' ||
    host.endsWith('.instagr.am');

/// Parse a supported post page. Unsupported hosts fail with UNSUPPORTED_URL.
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
  if (_isXhsHost(host)) return parseXhs(html, pageUrl);
  if (_isInstagramHost(host)) return parseInstagram(html, pageUrl);
  return ParseResult.err(
    ParseError(
      code: ParseErrorCode.unsupportedUrl,
      message: 'Unsupported host: $host',
    ),
  );
}
