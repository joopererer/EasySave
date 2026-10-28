import 'package:easysave/services/preview_video.dart';
import 'package:easysave/services/saver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TikTok preview uses download Referer and reads only TikTok session', () async {
    final headers = await previewVideoHeaders('tiktok', readCookie: (urls) async {
      expect(urls, ['https://www.tiktok.com/']);
      return 'fixture=FAKE';
    });
    expect(headers, {'Referer': 'https://www.tiktok.com/', 'Cookie': 'fixture=FAKE'});
  });
  for (final platform in ['xhs', 'x', 'instagram']) {
    test('$platform preview never reads TikTok credentials', () async {
      final headers = await previewVideoHeaders(platform, readCookie: (_) async => throw StateError('must not read'));
      expect(headers, {'Referer': refererFor(platform)});
    });
  }
  test('empty TikTok session is omitted and errors suggest offline viewing', () async {
    expect(await previewVideoHeaders('tiktok', readCookie: (_) async => ''), {'Referer': 'https://www.tiktok.com/'});
    expect(previewPlaybackError('tiktok'), contains('请下载后观看'));
  });
}
