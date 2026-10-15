import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
