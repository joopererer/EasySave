import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  for (final url in ['vm.tiktok.com/xxx', 'xhslink.cn/o/xxx', 'www.instagram.com/p/xxx']) {
    test('normalizes and extracts $url', () {
      expect(normalizeSupportedLink(url), 'https://$url');
      expect(extractLink('分享：$url。'), 'https://$url');
      expect(isSupportedLink(url), isTrue);
      expect(extractLinks('$url https://$url'), ['https://$url']);
    });
  }
  for (final value in ['ordinary words', 'notxhslink.cn/o/xxx', 'xhslink.cn.evil.com/o/a',
    'user@xhslink.cn/o/a', 'evil.com/xhslink.cn/o/a', 'ftp://xhslink.cn/o/a']) {
    test('does not extract unknown or embedded domain $value', () {
      expect(extractLink(value), isNull);
      expect(normalizeSupportedLink(value), value);
    });
  }
}
