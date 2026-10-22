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

  group('decideBubbleAction (Issue 2: floating bubble deduplication)', () {
    final records = <KnownPost>[
      (postUrl: 'https://www.xiaohongshu.com/explore/$xhsId', postId: xhsId),
      (
        postUrl: 'https://www.instagram.com/p/DeM3KzPktAC/',
        postId: 'DeM3KzPktAC',
      ),
    ];

    test('already on preview page: skip navigation', () {
      // Currently viewing the Instagram post on the preview page
      expect(
        decideBubbleAction(
          'https://www.instagram.com/p/DeM3KzPktAC/',
          currentPreviewPostId: 'DeM3KzPktAC',
          knownPosts: records,
        ),
        BubbleAction.skipAlreadyOnPreview,
      );
    });

    test('left preview page but post in history: open cached', () {
      // Not on any preview page, but XHS post is in history
      expect(
        decideBubbleAction(
          'https://www.xiaohongshu.com/explore/$xhsId',
          currentPreviewPostId: null,
          knownPosts: records,
        ),
        BubbleAction.openCached,
      );
    });

    test('post in history: open cached', () {
      // On a different preview page, but link is in history
      expect(
        decideBubbleAction(
          'https://www.instagram.com/p/DeM3KzPktAC/',
          currentPreviewPostId: xhsId, // Different post
          knownPosts: records,
        ),
        BubbleAction.openCached,
      );
    });

    test('post not in history: parse fresh', () {
      // Link not in history and not currently on preview
      expect(
        decideBubbleAction(
          'https://www.instagram.com/p/OtherCode1/',
          currentPreviewPostId: null,
          knownPosts: records,
        ),
        BubbleAction.parseFresh,
      );
    });

    test('short link resolved through redirect: open cached', () {
      // Short link that resolves to a post in history
      expect(
        decideBubbleAction(
          'http://xhslink.com/a/abc',
          currentPreviewPostId: null,
          knownPosts: records,
          resolvedUrl: 'https://www.xiaohongshu.com/explore/$xhsId',
        ),
        BubbleAction.openCached,
      );
    });

    test('already on preview but different resolution: still skip', () {
      // Case-insensitive comparison: currently on preview with lowercase ID
      expect(
        decideBubbleAction(
          'https://www.xiaohongshu.com/explore/${xhsId.toUpperCase()}',
          currentPreviewPostId: xhsId,
          knownPosts: records,
        ),
        BubbleAction.skipAlreadyOnPreview,
      );
    });
  });

  group('postIdOfUrl', () {
    test('extracts 24-hex XHS note id', () {
      expect(
        postIdOfUrl('https://www.xiaohongshu.com/explore/6ace0d440000000013019638'),
        '6ace0d440000000013019638',
      );
    });

    test('extracts modern alphanumeric XHS note id from /discovery/item/ and /explore/', () {
      expect(
        postIdOfUrl('https://www.xiaohongshu.com/discovery/item/DeqdQQPHcYe?xsec_token=xyz'),
        'DeqdQQPHcYe',
      );
      expect(
        postIdOfUrl('https://www.xiaohongshu.com/explore/DeqdQQPHcYe'),
        'DeqdQQPHcYe',
      );
    });

    test('extracts Douyin and TikTok video/note ids', () {
      expect(
        postIdOfUrl('https://www.douyin.com/video/7123456789012345678'),
        '7123456789012345678',
      );
      expect(
        postIdOfUrl('https://www.douyin.com/note/7123456789012345678'),
        '7123456789012345678',
      );
      expect(
        postIdOfUrl('https://www.tiktok.com/@user/video/7123456789012345678'),
        '7123456789012345678',
      );
    });

    test('extracts Bilibili, Instagram, X status ids', () {
      expect(
        postIdOfUrl('https://www.bilibili.com/video/BV1xx411c7mD'),
        'BV1xx411c7mD',
      );
      expect(
        postIdOfUrl('https://www.instagram.com/reel/CxYzAbCdEfG/'),
        'CxYzAbCdEfG',
      );
      expect(
        postIdOfUrl('https://x.com/user/status/1234567890'),
        '1234567890',
      );
    });

    test('returns null for unparseable or short URLs', () {
      expect(postIdOfUrl('https://xhslink.cn/o/5E0mBMnzaH4'), isNull);
      expect(postIdOfUrl('https://v.douyin.com/iABCDEF/'), isNull);
      expect(postIdOfUrl('not a url'), isNull);
    });
  });
}

