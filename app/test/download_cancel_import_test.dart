import 'dart:async';

import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel waits for album import and keeps a completed file', () async {
    final job = DownloadJob(
      key: 'cancel-import-1',
      label: '图片 1',
      filename: 'post_1.jpg',
      urls: const ['https://sns-img-hw.xhscdn.com/post.jpg'],
      isImage: true,
      itemIndex: 1,
    )..state = JobState.active;
    final batch = DownloadBatch(
      batchId: 'cancel-import',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/post',
      platform: 'xhs',
      postId: 'post',
      jobs: [job],
    );
    final import = Completer<void>();
    final tracked = DownloadManager.instance.trackFinishForTesting(
      job.key,
      () => import.future,
    );
    var cancelReturned = false;
    final cancel = DownloadManager.instance.cancelJob(batch, job).then((_) {
      cancelReturned = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(cancelReturned, isFalse);
    job
      ..saved = true
      ..state = JobState.done
      ..mediaId = '42';
    import.complete();
    await Future.wait([tracked, cancel]);
    expect(cancelReturned, isTrue);
    expect(job.state, JobState.done);
    expect(job.saved, isTrue);
  });
}
