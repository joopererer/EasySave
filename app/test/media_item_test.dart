import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local history files are not network URLs', () {
    final record = HistoryRecord(
      platform: 'xhs', postId: 'abc', postUrl: 'https://example.test/abc',
      fileCount: 2, createdAt: DateTime(2026),
      files: [
        HistoryFile(filename: 'one.jpg', savedAt: 0, itemIndex: 1),
        HistoryFile(filename: 'two.jpg', savedAt: 0, itemIndex: 2),
        HistoryFile(filename: 'two.mp4', savedAt: 0, itemIndex: 2, isImage: false),
      ],
    );
    final items = record.toPost().items;
    expect(items[0].url, isEmpty);
    expect(items[0].localFilename, 'one.jpg');
    expect(items[1].url, isEmpty);
    expect(items[1].videoUrl, isNull);
    expect(items[1].localFilename, 'two.jpg');
    expect(items[1].localVideoFilename, 'two.mp4');
  });
  test('legacy local URL uses a valid remote fallback separately', () {
    final record = HistoryRecord(
      platform: 'xhs', postId: 'abc', postUrl: 'https://example.test/abc',
      fileCount: 1, createdAt: DateTime(2026),
      itemsJson: jsonEncode([
        {'type': 'image', 'url': 'local.jpg',
          'fallbacks': ['https://sns-webpic-qc.xhscdn.com/image.jpg']},
      ]),
    );
    final item = record.toPost().items.single;
    expect(item.localFilename, 'local.jpg');
    expect(item.url, startsWith('https://'));
  });
  test('MediaItem fallbacks survive the history round-trip', () {
    final item = MediaItem(
      type: 'live',
      url: 'https://ci/primary.jpg',
      videoUrl: 'https://ci/motion.mp4',
      fallbacks: ['https://cdn/a.jpg', 'https://cdn/b.jpg'],
    );
    final record = HistoryRecord(
      platform: 'xhs',
      postId: 'abc',
      postUrl: 'https://www.xiaohongshu.com/explore/abc',
      fileCount: 1,
      createdAt: DateTime(2026, 1, 1),
      itemsJson: jsonEncode([item.toJson()]),
    );
    final post = PreviewPage.postFromRecord(record);
    expect(post.items.single.fallbacks, [
      'https://cdn/a.jpg',
      'https://cdn/b.jpg',
    ]);
  });
}
