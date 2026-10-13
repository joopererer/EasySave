import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

// H5 and WB scenes without a watermark token are clean originals:
// H5_DTL first, then WB_DFT. Watermarked renditions stay as fallbacks.
void main() {
  Map<String, Object?> noteWith(List<Map<String, Object?>> images) => {
    'noteId': '6aca089a000000000a01efb4',
    'title': 't',
    'user': {'nickname': 'momo'},
    'imageList': images,
  };

  const ciToken = 'notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0';
  const clean =
      'http://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/$ciToken!nd_dft_wlteh_webp_3';
  const marked =
      'http://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/$ciToken!nd_dft_wlteh_webp_watermark_3';
  const direct =
      'http://sns-webpic-qc.xhscdn.com/202610132252/fccfbed52a062a916648e7d56c157af7/$ciToken!h5_1080jpg';

  group('watermark-free scene selection', () {
    test('H5_DTL wins over WB_DFT and the watermarked rendition', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 1290,
            'height': 1608,
            'urlDefault': direct,
            'fileId': ciToken,
            'infoList': [
              {'imageScene': 'WB_DFT', 'url': marked},
              {'imageScene': 'WB_DFT', 'url': clean},
              {'imageScene': 'H5_DTL', 'url': direct},
            ],
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(
        result.data?.items.single.url,
        equals(
          'https://sns-webpic-qc.xhscdn.com/202610132252/fccfbed52a062a916648e7d56c157af7/$ciToken!h5_1080jpg',
        ),
      );
      expect(
        result.data?.items.single.fallbacks,
        equals([
          'https://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/$ciToken!nd_dft_wlteh_webp_3',
          'https://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/$ciToken!nd_dft_wlteh_webp_watermark_3',
          'https://ci.xiaohongshu.com/$ciToken',
        ]),
      );
    });

    test(
      'falls back to the watermarked rendition when no clean one exists',
      () {
        final result = buildNoteFromRecord(
          noteWith([
            {
              'width': 100,
              'height': 200,
              'infoList': [
                {'imageScene': 'WB_DFT', 'url': marked},
              ],
            },
          ]),
          '6aca089a000000000a01efb4',
        );
        expect(result.ok, isTrue);
        expect(
          result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/$ciToken'),
        );
        expect(result.data?.items.single.fallbacks, isEmpty);
      },
    );
  });
}
