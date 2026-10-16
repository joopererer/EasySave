import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('batch extraction from pasted text', () {
    test('three links in one block yields three parseable URLs', () {
      const text =
          '收藏合集：\n'
          '1. https://www.xiaohongshu.com/explore/aaa\n'
          '2. http://xhslink.com/a/bbb\n'
          '3. https://www.instagram.com/p/Ccc_1d2Ef3/';
      final links = extractLinks(text);
      expect(links, hasLength(3));
      expect(links[0], 'https://www.xiaohongshu.com/explore/aaa');
      expect(links[1], 'http://xhslink.com/a/bbb');
      expect(links[2], 'https://www.instagram.com/p/Ccc_1d2Ef3/');
    });

    test('mixed supported and unsupported keeps only supported', () {
      final links = extractLinks(
        'https://example.com/x https://www.xiaohongshu.com/explore/aaa',
      );
      expect(links, equals(['https://www.xiaohongshu.com/explore/aaa']));
    });

    test('trailing punctuation on each line is stripped', () {
      final links = extractLinks(
        'https://www.xiaohongshu.com/explore/aaa。\n'
        'https://www.instagram.com/p/Bbb/，',
      );
      expect(links, [
        'https://www.xiaohongshu.com/explore/aaa',
        'https://www.instagram.com/p/Bbb/',
      ]);
    });
  });
}
