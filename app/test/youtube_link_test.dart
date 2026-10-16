import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractLinks', () {
    test('returns all supported links in order', () {
      expect(
        extractLinks(
          '看这三个 https://www.xiaohongshu.com/explore/aaa '
          'https://example.com/nope '
          'https://www.instagram.com/p/Bbb/ '
          'https://xhslink.com/a/ccc',
        ),
        equals([
          'https://www.xiaohongshu.com/explore/aaa',
          'https://www.instagram.com/p/Bbb/',
          'https://xhslink.com/a/ccc',
        ]),
      );
    });

    test('dedupes repeats and respects the limit', () {
      const link = 'https://www.xiaohongshu.com/explore/aaa';
      expect(extractLinks('$link $link', limit: 9), equals([link]));
      final many = List.filled(12, link).join(' ');
      expect(extractLinks(many).length, 1);
      final distinct = [
        for (var i = 0; i < 12; i++)
          'https://www.xiaohongshu.com/explore/post$i',
      ].join(' ');
      expect(extractLinks(distinct).length, 9);
    });

    test('returns empty when nothing supported', () {
      expect(extractLinks('今天天气不错 https://example.com/a'), isEmpty);
    });
  });

  group('isYouTubeLink', () {
    test('matches watch, shorts and youtu.be', () {
      expect(
        isYouTubeLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isTrue,
      );
      expect(
        isYouTubeLink('https://m.youtube.com/watch?v=dQw4w9WgXcQ'),
        isTrue,
      );
      expect(isYouTubeLink('https://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(
        isYouTubeLink('https://www.youtube.com/shorts/abc123XYZ_-'),
        isTrue,
      );
    });

    test('rejects non-video pages and lookalikes', () {
      expect(isYouTubeLink('https://www.youtube.com/'), isFalse);
      expect(isYouTubeLink('https://www.youtube.com/feed/trending'), isFalse);
      expect(isYouTubeLink('https://www.youtube.com/watch'), isFalse);
      expect(isYouTubeLink('https://www.notyoutube.com/watch?v=abc'), isFalse);
      expect(isYouTubeLink('https://www.xiaohongshu.com/explore/abc'), isFalse);
      expect(isYouTubeLink('not a url'), isFalse);
    });
  });

  group('extractYouTubeLink', () {
    test('finds a YouTube URL inside free text', () {
      expect(
        extractYouTubeLink('这个视频绝了 https://youtu.be/dQw4w9WgXcQ 快看'),
        equals('https://youtu.be/dQw4w9WgXcQ'),
      );
    });

    test('ignores non-YouTube links', () {
      expect(
        extractYouTubeLink('https://www.xiaohongshu.com/explore/abc'),
        isNull,
      );
    });
  });
}
