import 'package:easysave/core/instagram.dart';
import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

// duration is optional: present from video.capa.duration (XHS) or
// video_duration (IG), absent otherwise (UI shows a bare play badge).
void main() {
  group('video duration', () {
    test('xhs reads duration from video.capa', () {
      const id = '6aca089a000000000a01efb4';
      final result = parseXhsState({
        'note': {
          'noteDetailMap': {
            id: {
              'note': {
                'noteId': id,
                'type': 'video',
                'title': 't',
                'desc': 'd',
                'time': 1791625370000,
                'user': {
                  'nickname': 'momo',
                  'userId': '604e0d4800000000010065ec',
                },
                'imageList': [],
                'video': {
                  'consumer': {'originVideoKey': 'https://example.com/v.mp4'},
                  'capa': {'duration': 14},
                },
              },
            },
          },
        },
      }, 'https://www.xiaohongshu.com/explore/$id');
      expect(result.ok, isTrue);
      expect(result.data?.items.single.toJson()['duration'], equals(14));
    });

    test('xhs omits duration without capa', () {
      const id = '6aca089a000000000a01efb4';
      final result = parseXhsState({
        'note': {
          'noteDetailMap': {
            id: {
              'note': {
                'noteId': id,
                'type': 'video',
                'title': 't',
                'desc': 'd',
                'time': 1791625370000,
                'user': {
                  'nickname': 'momo',
                  'userId': '604e0d4800000000010065ec',
                },
                'imageList': [],
                'video': {
                  'consumer': {'originVideoKey': 'https://example.com/v.mp4'},
                },
              },
            },
          },
        },
      }, 'https://www.xiaohongshu.com/explore/$id');
      expect(result.ok, isTrue);
      expect(
        result.data?.items.single.toJson().containsKey('duration'),
        isFalse,
      );
    });

    test('instagram reads duration from video_duration', () {
      final result = buildPostFromProduct({
        'id': '1',
        'video_versions': [
          {'url': 'https://example.com/v.mp4', 'width': 720, 'height': 1280},
        ],
        'image_versions2': {
          'candidates': [
            {'url': 'https://example.com/p.jpg', 'width': 720, 'height': 1280},
          ],
        },
        'video_duration': 8.5,
        'taken_at': 1791606584,
        'user': {'username': 'momo'},
        'caption': {'text': 'hi'},
      }, 'B');
      expect(result.ok, isTrue);
      if (result.ok) {
        expect(result.data?.items.single.toJson()['duration'], equals(8.5));
      }
    });
  });
}
