import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeJsUndefined', () {
    test('replaces undefined outside strings but keeps it inside strings', () {
      expect(
        sanitizeJsUndefined('{"a":undefined,"b":"say undefined loudly"}'),
        equals('{"a":null,"b":"say undefined loudly"}'),
      );
      expect(sanitizeJsUndefined('{"a":null}'), equals('{"a":null}'));
      expect(
        sanitizeJsUndefined('[undefined,null,"undefined"]'),
        equals('[null,null,"undefined"]'),
      );
    });

    test('parses state containing JS undefined without touching strings', () {
      const id = '6aca089a000000000a01efb4';
      final html =
          '<html><head><script>window.__INITIAL_STATE__={"global":{"x":undefined},'
          '"note":{"noteDetailMap":{"$id":{"note":{"noteId":"$id",'
          '"title":"say undefined loudly","desc":"d","time":1791625370000,'
          '"user":{"nickname":"momo","userId":"604e0d4800000000010065ec"},'
          '"imageList":[{"urlDefault":"http://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208!nd_dft_wlteh_webp_3","width":1290,"height":1608}]}}}}'
          '</script></head></html>';
      final result = parseXhs(html, 'https://www.xiaohongshu.com/explore/$id');
      expect(result.ok, isTrue);
      expect(result.data?.title, equals('say undefined loudly'));
      expect(
        result.data?.items.map((i) => i.toJson()).toList(),
        equals([
          {
            'type': 'image',
            'url':
                'https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208',
            'width': 1290,
            'height': 1608,
            'fallbacks': [
              'https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208?imageView2/format/jpg',
              'https://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208!nd_dft_wlteh_webp_3',
              'https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208',
            ],
          },
        ]),
      );
    });

    test('parseXhsState accepts decoded INITIAL_STATE JSON directly', () {
      const id = '6aca089a000000000a01efb4';
      final result = parseXhsState({
        'note': {
          'noteDetailMap': {
            id: {
              'note': {
                'noteId': id,
                'title': 't',
                'desc': 'd',
                'time': 1791625370000,
                'user': {
                  'nickname': 'momo',
                  'userId': '604e0d4800000000010065ec',
                },
                'imageList': [
                  {
                    'urlDefault': 'https://sns-img-bd.xhscdn.com/trace',
                    'width': 10,
                    'height': 20,
                  },
                ],
              },
            },
          },
        },
      }, 'https://www.xiaohongshu.com/explore/$id');
      expect(result.ok, isTrue);
      expect(
        result.data?.toJson(),
        equals({
          'platform': 'xhs',
          'id': id,
          'url': 'https://www.xiaohongshu.com/explore/$id',
          'author': {'name': 'momo', 'id': '604e0d4800000000010065ec'},
          'title': 't',
          'caption': 'd',
          'publishedAt': '2026-10-10T09:42:50Z',
          'items': [
            {
              'type': 'image',
              'url': 'https://sns-img-bd.xhscdn.com/trace',
              'width': 10,
              'height': 20,
              'fallbacks': [
                'https://ci.xiaohongshu.com/trace?imageView2/format/jpg',
                'https://ci.xiaohongshu.com/trace',
              ],
            },
          ],
        }),
      );
    });
  });
}
