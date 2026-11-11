import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '1234567890123456789';
  test('TikTok forms use manifest canonicalization including photo posts', () {
    for (final host in ['www.tiktok.com', 'm.tiktok.com']) {
      for (final path in [
        '/@person/video/$id',
        '/@person/photo/$id',
        '/v/$id.html',
        '/share/video/$id',
      ]) {
        final url = 'https://$host$path?tracking=FAKE';
        expect(isSupportedLink(url), isTrue);
        expect(
          SiteRegistry.current.canonicalUrl(url),
          'https://www.tiktok.com/@/video/$id',
        );
        expect(extractLink('分享 $url。'), url);
      }
    }
  });
  test('short links are followed by the WebView, history lookup uses HTTP',
      () async {
    for (final host in ['vm.tiktok.com', 'vt.tiktok.com']) {
      final url = 'https://$host/abc/';
      expect(isSupportedLink(url), isTrue);
      expect(SiteRegistry.current.canonicalUrl(url), isNull);
      final target = 'https://www.tiktok.com/@person/video/$id';
      // v1.9.0 parity: the parse path must not expand a webview short link.
      expect(
        await resolveShortLink(url, readRedirect: (_) async => target),
        url,
      );
      Future<String?> redirect(Uri uri) async =>
          uri.host == host ? target : null;
      expect(
        await resolveShortLink(url, forHistoryLookup: true, readRedirect: redirect),
        target,
      );
    }
  });
  test('rejects lookalikes, unrelated paths and non-http schemes', () {
    for (final url in [
      'https://www.tiktok.com.evil/@person/video/$id',
      'https://evil/?url=https://www.tiktok.com/@person/video/$id',
      'javascript://www.tiktok.com/@person/video/$id',
      'https://www.tiktok.com/@person',
    ]) {
      expect(SiteRegistry.current.match(url), isNull);
      expect(SiteRegistry.current.canonicalUrl(url), isNull);
    }
  });
}
