import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

// Entries without urlDefault/url must still resolve through infoList
// renditions or fileId (regression test for blank preview thumbnails).
void main() {
  Map<String, Object?> noteWith(List<Map<String, Object?>> images) => {
        'noteId': '6aca089a000000000a01efb4',
        'title': 't',
        'user': {'nickname': 'momo'},
        'imageList': images,
      };

  group('imageUrlOf fallbacks', () {
    test('prefers the WB_DFT rendition from infoList', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 100,
            'height': 200,
            'infoList': [
              {
                'imageScene': 'WB_PRV',
                'url': 'http://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/notes_pre_post/x!nd_prv_wlteh_webp_3',
              },
              {
                'imageScene': 'WB_DFT',
                'url': 'http://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/x!nd_dft_wlteh_webp_3',
              },
            ],
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/notes_pre_post/x'));
    });

    test('falls back to the first infoList rendition without a DFT scene', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 100,
            'height': 200,
            'infoList': [
              {
                'imageScene': 'WB_PRV',
                'url': 'http://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/notes_pre_post/y!nd_prv_wlteh_webp_3',
              },
            ],
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/notes_pre_post/y'));
    });

    test('falls back to fileId for the ci host', () {
      final result = buildNoteFromRecord(
        noteWith([
          {
            'width': 100,
            'height': 200,
            'fileId': 'notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208',
            'traceId': 'sometrace',
          },
        ]),
        '6aca089a000000000a01efb4',
      );
      expect(result.ok, isTrue);
      expect(result.data?.items.single.url,
          equals('https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208'));
    });
  });
}
