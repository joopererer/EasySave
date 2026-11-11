// Platform dispatcher: picks the right pure parser from the page URL.
// In v1.3a+, parsing is handled by parser.js injected into the WebView.

import 'models.dart';
import '../services/site_registry.dart';

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
  if (SiteRegistry.current.match(pageUrl) == null) {
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
