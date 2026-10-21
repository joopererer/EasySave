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

  group('selective download provenance', () {
    ParsedPost post5() => ParsedPost(
      platform: 'instagram',
      id: 'Det2VeVn3tY',
      url: 'https://www.instagram.com/p/Det2VeVn3tY/',
      author: PostAuthor(name: 'someone'),
      items: [
        for (var i = 1; i <= 5; i++)
          MediaItem(type: 'image', url: 'https://img/$i.jpg'),
      ],
    );

    DownloadBatch batchFor(ParsedPost post, List<int> selected) {
      final planned = planFiles(post, selected, (l, s, e) => 'f$s');
      return DownloadBatch(
        batchId: 'b',
        album: 'EasySave',
        postUrl: post.url,
        platform: post.platform,
        postId: post.id,
        postItemCount: post.items.length,
        jobs: [
          for (var i = 0; i < planned.length; i++)
            DownloadJob(
              key: 'b-$i',
              label: planned[i].label,
              filename: planned[i].filename,
              urls: planned[i].urls,
              isImage: planned[i].isImage,
              itemIndex: planned[i].itemIndex,
            ),
        ],
      );
    }

    test('items 2 and 4 of 5 keep original index and post total', () {
      final batch = batchFor(post5(), [1, 3]);
      expect(batch.jobs.map((j) => j.itemIndex), [2, 4]);
      final p2 = provenanceForBatchItem(batch, itemIndex: batch.jobs[0].itemIndex);
      final p4 = provenanceForBatchItem(batch, itemIndex: batch.jobs[1].itemIndex);
      expect(p2.itemIndex, 2);
      expect(p2.itemCount, 5);
      expect(p4.itemIndex, 4);
      expect(p4.itemCount, 5);
    });

    test('a single selected item of a multi-item post keeps its index', () {
      final batch = batchFor(post5(), [1]);
      expect(batch.jobs, hasLength(1));
      final p = provenanceForBatchItem(batch, itemIndex: batch.jobs.single.itemIndex);
      expect(p.itemIndex, 2);
      expect(p.itemCount, 5);
    });

    test('a genuine single-item post still omits index and count', () {
      final single = ParsedPost(
        platform: 'instagram',
        id: 'one',
        url: 'https://www.instagram.com/p/one/',
        author: PostAuthor(name: 'a'),
        items: [MediaItem(type: 'image', url: 'https://img/1.jpg')],
      );
      final batch = batchFor(single, [0]);
      final p = provenanceForBatchItem(batch, itemIndex: 1);
      expect(p.itemIndex, isNull);
      expect(p.itemCount, isNull);
    });

    test('post total survives the snapshot round trip', () {
      final batch = batchFor(post5(), [1, 3]);
      final restored = DownloadBatch.fromJson(
        batch.toJson().map((k, v) => MapEntry(k, v is List ? List.of(v) : v)),
      );
      expect(restored.postItemCount, 5);
      expect(restored.totalItems, 5);
    });

    test('legacy snapshot without postItemCount falls back to itemsJson', () {
      final legacy = DownloadBatch(
        batchId: 'b',
        album: 'EasySave',
        postUrl: 'u',
        platform: 'instagram',
        postId: 'p',
        itemsJson: '[{},{},{},{},{}]',
        jobs: [
          DownloadJob(
            key: 'b-0',
            label: 'l',
            filename: 'f.jpg',
            urls: ['u'],
            isImage: true,
            itemIndex: 2,
          ),
        ],
      );
      expect(legacy.totalItems, 5);
    });

    test('Live item: still and motion jobs both carry the original index', () {
      final live = ParsedPost(
        platform: 'xhs',
        id: 'n1',
        url: 'https://www.xiaohongshu.com/explore/n1',
        author: PostAuthor(name: 'a'),
        items: [
          MediaItem(type: 'image', url: 'https://img/1.jpg'),
          MediaItem(type: 'live', url: 'https://img/2.jpg', videoUrl: 'https://v/2.mp4'),
          MediaItem(type: 'image', url: 'https://img/3.jpg'),
        ],
      );
      final batch = batchFor(live, [1]);
      expect(batch.jobs.map((j) => j.itemIndex), [2, 2]);
      final p = provenanceForBatchItem(batch, itemIndex: 2);
      expect(p.itemIndex, 2);
      expect(p.itemCount, 3);
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
