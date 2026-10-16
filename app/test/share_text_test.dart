import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/share_service.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadBatch _batch({String? author, String? title, String? caption}) =>
    DownloadBatch(
      batchId: 'b1',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/abc',
      platform: 'xhs',
      postId: 'abc',
      authorName: author,
      title: title,
      caption: caption,
      jobs: [
        DownloadJob(
          key: 'b1-0',
          label: '图片 1',
          filename: 'f1.jpg',
          urls: ['https://cdn/a.jpg'],
          isImage: true,
          itemIndex: 0,
        )..state = JobState.done,
        DownloadJob(
          key: 'b1-1',
          label: '视频 1',
          filename: 'f2.mp4',
          urls: ['https://cdn/b.mp4'],
          isImage: false,
          itemIndex: 1,
        )..state = JobState.done,
      ],
    );

void main() {
  group('shareTextFor', () {
    test('includes author, title, caption and post link', () {
      final text = shareTextFor(
        _batch(author: 'momo', title: '标题', caption: '正文'),
      );
      expect(text, contains('作者：momo'));
      expect(text, contains('标题'));
      expect(text, contains('正文'));
      expect(text, contains('原帖：https://www.xiaohongshu.com/explore/abc'));
    });

    test('skips missing author/title/caption without blank lines', () {
      final text = shareTextFor(_batch());
      expect(text, equals('原帖：https://www.xiaohongshu.com/explore/abc'));
    });
  });

  group('shareableImageJobs', () {
    test('returns only completed image jobs', () {
      final jobs = shareableImageJobs(_batch());
      expect(jobs, hasLength(1));
      expect(jobs.single.isImage, isTrue);
    });

    test('excludes non-done jobs', () {
      final batch = _batch();
      batch.jobs.first.state = JobState.failed;
      expect(shareableImageJobs(batch), isEmpty);
    });
  });
}
