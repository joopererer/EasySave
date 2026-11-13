// v1.10.3 build 47 — the attempt counter and its limit disagreed.
//
// Build 46 logged `item failed … attempt=5/3` and `attempt=6/3`: the numerator
// counted every transfer of the file while the denominator printed the
// per-candidate transfer limit (`kMaxAttempts`), so a still that walked several
// candidates looked like it had overrun a limit it never had. The same batch
// showed 220 `REQUEST_HEADER_REJECTED` lines because a policy rejection — which
// can never succeed on a retry — was re-enqueued by the reconciler until the
// real budget ran out.
//
// This test pins both halves: the line reports the file's real budget, and a
// policy rejection is final.

import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postId = '6af1ad13000000003400572d';

const _candidates = [
  'https://sns-img-bd.xhscdn.com/notes_pre_post/a?imageView2/format/jpg/q/100',
  'https://ci.xiaohongshu.com/notes_pre_post/a?imageView2/format/jpg',
  'https://sns-img-bd.xhscdn.com/notes_pre_post/a',
  'https://sns-webpic-qc.xhscdn.com/1/a!nd_prv_wlteh_webp_3',
];

DownloadJob _job({int attempts = 1}) => DownloadJob(
  key: 'job-1',
  label: '图片 1',
  filename: '${_postId}_1.jpg',
  urls: _candidates,
  isImage: true,
  itemIndex: 1,
)..attempts = attempts;

DownloadBatch _batch(List<DownloadJob> jobs) => DownloadBatch(
  batchId: 'attempt-cap',
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
  platform: 'xhs',
  postId: _postId,
  itemsJson: '[]',
  postItemCount: jobs.length,
  jobs: jobs,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
  });

  tearDown(() {
    manager
      ..enqueueForTesting = null
      ..clearBatchesForTesting();
    SiteRegistry.useBuiltin();
  });

  test('the failure line reports the budget the file really has', () {
    final job = _job(attempts: 5)..state = JobState.failed;
    final batch = _batch([job]);
    // Four candidates x (1 transfer + 3 backoff retries).
    final cap = retryCapFor(batch, job);
    expect(cap, _candidates.length * (1 + kCandidateRetryLimit));
    expect(cap, greaterThan(kMaxAttempts));

    final line = failedJobLogLine(batch, job);
    expect(line, contains('attempt=5/$cap'));
    expect(line, isNot(contains('/$kMaxAttempts ')));
    expect(line, contains('role='));
    expect(line, isNot(contains('http')));
    expect(line, isNot(contains('xiaohongshu')));
  });

  test('a video keeps the site rule as its budget', () {
    final job = DownloadJob(
      key: 'job-v',
      label: '视频 1',
      filename: '${_postId}_1.mp4',
      urls: ['https://sns-video-zl.xhscdn.com/stream/1/clip.mp4'],
      isImage: false,
      itemIndex: 1,
    )..attempts = 4;
    job.state = JobState.failed;
    final batch = _batch([job]);
    expect(
      retryCapFor(batch, job),
      attemptCapFor(batch, job) * (1 + kCandidateRetryLimit),
    );
    expect(
      failedJobLogLine(batch, job),
      contains('attempt=4/${retryCapFor(batch, job)}'),
    );
  });

  test('a policy rejection ends the file instead of retrying it', () async {
    final job = _job();
    manager.setBatchForTesting(_batch([job]));
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;
    final logs = <String>[];
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    try {
      await manager.taskFailureForTesting(
        _batch([job]),
        job,
        TaskStatusUpdate(
          DownloadTask(
            taskId: 'job-1-try1',
            url: _candidates.first,
            filename: 'x.jpg',
          ),
          TaskStatus.failed,
          TaskException('REQUEST_HEADER_REJECTED host=sns-img-bd.xhscdn.com'),
        ),
      );
    } finally {
      debugPrint = debugPrintThrottled;
    }

    expect(job.state, JobState.failed);
    expect(isPolicyRejected(job), isTrue);
    expect(job.errorCode, policyRejectedCode);
    expect(job.error, '该资源地址不在允许范围内');
    expect(enqueued, 0, reason: 'a forbidden URL is never asked twice');
    expect(logs.join('\n'), contains('attempt=1/${retryCapFor(_batch([job]), job)}'));
    expect(logs.join('\n'), contains('reason=POLICY'));
  });

  test('a transient failure still retries', () async {
    final job = _job();
    manager.setBatchForTesting(_batch([job]));
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;
    await manager.taskFailureForTesting(
      _batch([job]),
      job,
      TaskStatusUpdate(
        DownloadTask(taskId: 'job-1-try1', url: _candidates.first, filename: 'x.jpg'),
        TaskStatus.failed,
        TaskException('boom'),
      ),
    );
    expect(enqueued, 1);
    expect(isPolicyRejected(job), isFalse);
    expect(job.candidateIndex, 1, reason: 'a plain failure rotates candidate');
  });
}
