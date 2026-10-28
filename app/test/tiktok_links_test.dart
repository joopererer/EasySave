import 'package:easysave/services/links.dart';
import 'package:easysave/services/tiktok_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '1234567890123456789';
  test('TikTok forms use package canonicalization including photo posts', () {
    for (final host in ['www.tiktok.com', 'm.tiktok.com']) {
      for (final path in ['/@person/video/$id', '/@person/photo/$id',
        '/v/$id.html', '/share/video/$id']) {
        final url = 'https://$host$path?tracking=FAKE';
        expect(isSupportedLink(url), isTrue);
        expect(canonicalTiktokUrl(url), 'https://www.tiktok.com/@/video/$id');
        expect(extractLink('分享 $url。'), url);
      }
    }
  });
  test('short links remain unchanged until expanded by WebView', () async {
    for (final host in ['vm.tiktok.com', 'vt.tiktok.com']) {
      final url = 'https://$host/abc/';
      expect(isSupportedLink(url), isTrue);
      expect(canonicalTiktokUrl(url), isNull);
      expect(await resolveShortLink(url), url);
    }
  });
  test('rejects lookalikes, unrelated paths and non-http schemes', () {
    for (final url in ['https://www.tiktok.com.evil/@person/video/$id',
      'https://evil/?url=https://www.tiktok.com/@person/video/$id',
      'javascript://www.tiktok.com/@person/video/$id',
      'https://www.tiktok.com/@person']) {
      expect(isTiktokLink(url), isFalse);
      expect(canonicalTiktokUrl(url), isNull);
    }
  });
}
