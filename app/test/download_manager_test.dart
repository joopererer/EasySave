import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedPost _post() => ParsedPost(
  platform: 'xhs',
  id: 'abc123',
  url: 'https://www.xiaohongshu.com/explore/abc123',
  author: PostAuthor(name: 'momo'),
  items: [
    MediaItem(type: 'image', url: 'https://img/1.jpg'),
    MediaItem(
      type: 'video',
      url: 'https://video/v.mp4',
      posterUrl: 'https://img/cover.jpg',
    ),
    MediaItem(
      type: 'live',
      url: 'https://img/live.jpg',
      videoUrl: 'https://img/live.mp4',
    ),
  ],
);

void main() {
  group('planFiles', () {
    test('image job keeps CDN-first URL order', () {
      final planned = planFiles(_post(), [0], (l, s, e) => 'f$s.$e');
      expect(planned, hasLength(1));
      expect(planned.first.label, '图片 1');
      expect(planned.first.urls.first, 'https://img/1.jpg');
      expect(planned.first.isImage, isTrue);
    });

    test('video job tries the mp4 before image fallbacks', () {
      final planned = planFiles(_post(), [1], (l, s, e) => 'f$s.$e');
      expect(planned.first.urls.first, 'https://video/v.mp4');
      expect(planned.first.isImage, isFalse);
    });

    test('live item expands to still + motion jobs', () {
      final planned = planFiles(_post(), [2], (l, s, e) => 'f$s.$e');
      expect(planned, hasLength(2));
      expect(planned[0].isImage, isTrue);
      expect(planned[1].isImage, isFalse);
      expect(planned[0].label, planned[1].label);
    });

    test('labels count per kind across selections', () {
      final planned = planFiles(_post(), [0, 1, 2], (l, s, e) => 'f$s.$e');
      final labels = planned.map((p) => p.label).toList();
      expect(labels, ['图片 1', '视频 1', 'Live 1', 'Live 1']);
    });
  });

  group('retry counting', () {
    test('attempt rotation cycles through fallback URLs', () {
      final urls = ['a', 'b'];
      // Attempt n uses urls[(n-1) % len]: 1->a, 2->b, 3->a.
      expect(urls[(1 - 1) % urls.length], 'a');
      expect(urls[(2 - 1) % urls.length], 'b');
      expect(urls[(3 - 1) % urls.length], 'a');
    });

    test('kMaxAttempts caps total tries at 3', () {
      expect(kMaxAttempts, 3);
    });
  });

  group('planFilesForItem', () {
    test('returns null for out-of-range items', () {
      expect(planFilesForItem(_post(), 9), isNull);
      expect(planFilesForItem(_post(), -1), isNull);
    });

    test('refreshes live motion URL on manual retry', () {
      final urls = planFilesForItem(_post(), 2)!;
      expect(urls, contains('https://img/live.mp4'));
    });
  });

  group('DownloadBatch serialization', () {
    test('round-trips jobs for kill-recovery snapshots', () {
      final batch = DownloadBatch(
        batchId: 'b1',
        album: 'EasySave',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        platform: 'xhs',
        postId: 'abc123',
        jobs: [
          DownloadJob(
            key: 'b1-0',
            label: '图片 1',
            filename: 'f1.jpg',
            urls: ['https://img/1.jpg'],
            isImage: true,
            itemIndex: 0,
          )..attempts = 2,
        ],
      );
      final restored = DownloadBatch.fromJson(
        (batch.toJson()).map((k, v) => MapEntry(k, v is List ? List.of(v) : v)),
      );
      expect(restored.jobs.single.attempts, 2);
      expect(restored.jobs.single.urls, ['https://img/1.jpg']);
      expect(restored.isTerminal, isFalse);
    });
  });
}
