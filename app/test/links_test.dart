import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractLink', () {
    test('finds a full URL inside share copy', () {
      expect(
        extractLink('超好用 http://xhslink.com/a/bcd123，快来看看！'),
        equals('http://xhslink.com/a/bcd123'),
      );
    });

    test('strips trailing punctuation', () {
      expect(
        extractLink('看看这个：https://www.instagram.com/p/AbC123-_xYz/。'),
        equals('https://www.instagram.com/p/AbC123-_xYz/'),
      );
    });

    test('skips unsupported hosts and returns null when none found', () {
      expect(extractLink('https://example.com/a'), isNull);
      expect(extractLink('今天天气不错'), isNull);
    });

    test('takes the first supported link', () {
      expect(
        extractLink('https://example.com/a https://www.xiaohongshu.com/explore/abc'),
        equals('https://www.xiaohongshu.com/explore/abc'),
      );
    });
  });

  group('isSupportedLink', () {
    test('accepts platform and short-link hosts', () {
      expect(isSupportedLink('https://www.xiaohongshu.com/explore/x'), isTrue);
      expect(isSupportedLink('http://xhslink.com/a/b'), isTrue);
      expect(isSupportedLink('https://xhslink.cn/o/UJ01yHnFbS'), isTrue);
      expect(isSupportedLink('https://www.instagram.com/reels/abc/'), isTrue);
      expect(isSupportedLink('https://instagr.am/p/abc/'), isTrue);
      expect(isSupportedLink('https://evil-xiaohongshu.com/x'), isFalse);
    });
  });
}
