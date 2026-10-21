import 'package:easysave/services/clipboard_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const xhsId = '6ace0d440000000013019638';
  final records = <KnownPost>[
    (postUrl: 'https://www.xiaohongshu.com/explore/$xhsId', postId: xhsId),
    (
      postUrl: 'https://www.instagram.com/p/DeM3KzPktAC/',
      postId: 'DeM3KzPktAC',
    ),
  ];

  group('isLinkKnown', () {
    test('matches canonical url ignoring www, query and trailing slash', () {
      expect(
        isLinkKnown('https://instagram.com/p/DeM3KzPktAC?igsh=abc', records),
        isTrue,
      );
    });

    test('matches by post id when the url differs', () {
      expect(
        isLinkKnown(
          'https://www.xiaohongshu.com/discovery/item/$xhsId?xsec_token=x',
          records,
        ),
        isTrue,
      );
    });

    test('short link matches through its resolved url', () {
      expect(isLinkKnown('http://xhslink.com/a/abc', records), isFalse);
      expect(
        isLinkKnown(
          'http://xhslink.com/a/abc',
          records,
          resolvedUrl: 'https://www.xiaohongshu.com/explore/$xhsId?x=1',
        ),
        isTrue,
      );
    });

    test('unknown post is not known', () {
      expect(
        isLinkKnown('https://www.instagram.com/p/OtherCode1/', records),
        isFalse,
      );
    });
  });

  group('inputIsStale', () {
    bool known(String l) => isLinkKnown(l, records);

    test('input holding only an already downloaded link is stale', () {
      expect(
        inputIsStale('看看 https://www.instagram.com/p/DeM3KzPktAC/', known),
        isTrue,
      );
    });

    test('input with a not yet downloaded link is kept', () {
      expect(
        inputIsStale('https://www.instagram.com/p/OtherCode1/', known),
        isFalse,
      );
    });

    test('mixed known and unknown links are kept', () {
      expect(
        inputIsStale(
          'https://www.instagram.com/p/DeM3KzPktAC/ '
          'https://www.instagram.com/p/OtherCode1/',
          known,
        ),
        isFalse,
      );
    });

    test('text without a supported link is never stale', () {
      expect(inputIsStale('hello', known), isFalse);
      expect(inputIsStale('', known), isFalse);
    });
  });

  group('clipboardKeyOf', () {
    test('single link maps to the link itself', () {
      expect(
        clipboardKeyOf('copy https://www.instagram.com/p/DeM3KzPktAC/ now'),
        'https://www.instagram.com/p/DeM3KzPktAC/',
      );
    });

    test('several links map to a batch key', () {
      expect(
        clipboardKeyOf(
          'https://www.instagram.com/p/AAA/ https://www.instagram.com/p/BBB/',
        ),
        'batch:https://www.instagram.com/p/AAA/|https://www.instagram.com/p/BBB/',
      );
    });

    test('youtube link maps to its url, text without links to null', () {
      expect(
        clipboardKeyOf('https://youtu.be/dQw4w9WgXcQ'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      expect(clipboardKeyOf('nothing here'), isNull);
    });

    test('bubble url and clipboard text produce the same key', () {
      const link = 'https://www.instagram.com/p/DeM3KzPktAC/';
      expect(clipboardKeyOf(link), clipboardKeyOf('快来看 $link'));
    });
  });
}
