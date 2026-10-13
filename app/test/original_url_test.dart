import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

// Primary must be the bare original-bucket URL (upstream formula);
// JPEG transcode, scene renditions and the ci token trail as fallbacks.
void main() {
  Map<String, Object?> noteWith(List<Map<String, Object?>> images) => {
    'noteId': '6aca089a000000000a01efb4',
    'title': 't',
    'user': {'nickname': 'momo'},
    'imageList': images,
  };

  const ciToken = 'notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0';
  const h5 =
      'http://sns-webpic-qc.xhscdn.com/202610132252/fccfbed52a062a916648e7d56c157af7/$ciToken!h5_1080jpg';

  group('original-bucket primary', () {
    test('serves the bare token URL with JPEG transcode first fallback', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 1290,
            'height': 1608,
            'urlDefault': h5,
            'fileId': ciToken,
            'infoList': [
              {'imageScene': 'H5_DTL', 'url': h5},
              {
                'imageScene': 'H5_PRV',
                'url': h5.replaceAll('h5_1080jpg', 'style_d4c824bab532bfe9'),
              },
            ],
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(
        result.data?.items.single.url,
        equals('https://sns-img-bd.xhscdn.com/$ciToken'),
      );
      final fallbacks = result.data?.items.single.fallbacks ?? [];
      expect(
        fallbacks.first,
        equals('https://ci.xiaohongshu.com/$ciToken?imageView2/format/jpg'),
      );
      expect(fallbacks, contains('https://ci.xiaohongshu.com/$ciToken'));
      expect(
        result.data?.items.single.toJson().containsKey('fallbacks'),
        isFalse,
      );
    });

    test('falls back to fileId token when no URL is present', () {
      final result = buildNoteFromRecord(
        noteWith([
          {'width': 100, 'height': 200, 'fileId': 'notes_pre_post/x'},
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(
        result.data?.items.single.url,
        equals('https://sns-img-bd.xhscdn.com/notes_pre_post/x'),
      );
    });

    test('imageTokenOf strips the style suffix', () {
      expect(imageTokenOf(h5), equals(ciToken));
      expect(
        imageTokenOf('https://ci.xiaohongshu.com/$ciToken'),
        equals(ciToken),
      );
      expect(imageTokenOf('https://example.com/a.jpg'), isNull);
    });
  });
}
