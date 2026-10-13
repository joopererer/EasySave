import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

// WB_DFT renditions exist with and without watermark: the appended token
// decides (`wb_dft` clean vs `watermark`). Clean wins; marked is kept as
// the only fallback.
void main() {
  Map<String, Object?> noteWith(List<Map<String, Object?>> images) => {
        'noteId': '6aca089a000000000a01efb4',
        'title': 't',
        'user': {'nickname': 'momo'},
        'imageList': images,
      };

  const clean =
      'http://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0!nd_dft_wlteh_webp_3';
  const marked =
      'http://sns-webpic-qc.xhscdn.com/202610132252/7089f290924f748b44a1411f3ac4f189/notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0!nd_dft_wlteh_webp_watermark_3';

  group('watermark-free scene selection', () {
    test('clean WB_DFT wins over the watermarked rendition', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 1290,
            'height': 1608,
            'infoList': [
              {'imageScene': 'WB_DFT', 'url': marked},
              {'imageScene': 'WB_DFT', 'url': clean},
            ],
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0'));
      expect(
        result.data?.items.single.fallbacks,
        equals([
          'https://ci.xiaohongshu.com/notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0',
        ]),
      );
    });

    test('falls back to the watermarked rendition when no clean one exists', () {
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
      expect(result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0'));
      expect(result.data?.items.single.fallbacks, isEmpty);
    });
  });
}
