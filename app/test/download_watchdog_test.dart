import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadJob _job(String key, {JobState state = JobState.queued, int at = 0}) {
  final j = DownloadJob(
    key: key,
    label: 'img',
    filename: '$key.jpg',
    urls: const ['https://example.com/a.jpg'],
    isImage: true,
    itemIndex: 0,
  );
  j.state = state;
  j.lastProgressAt = at;
  return j;
}

DownloadBatch _batch(String id, List<DownloadJob> jobs, {int updatedAt = 0}) =>
    DownloadBatch(
      batchId: id,
      album: 'EasySave',
      postUrl: 'https://example.com/p/$id',
      platform: 'xhs',
      postId: 'post-$id',
      jobs: jobs,
      updatedAt: updatedAt,
    );

void main() {
  group('decideStalledAction', () {
    test('native still working keeps waiting', () {
      for (final s in [
        TaskStatus.enqueued,
        TaskStatus.running,
        TaskStatus.waitingToRetry,
        TaskStatus.paused,
      ]) {
        expect(
          decideStalledAction(nativeStatus: s, attempts: 1),
          StalledAction.keepWaiting,
        );
      }
    });

    test('finished native task is imported', () {
      expect(
        decideStalledAction(nativeStatus: TaskStatus.complete, attempts: 1),
        StalledAction.finishFile,
      );
    });

    test('lost or failed task retries until attempts are used up', () {
      expect(
        decideStalledAction(nativeStatus: null, attempts: 1),
        StalledAction.retry,
      );
      expect(
        decideStalledAction(nativeStatus: TaskStatus.failed, attempts: 2),
        StalledAction.retry,
      );
      expect(
        decideStalledAction(nativeStatus: null, attempts: kMaxAttempts),
        StalledAction.fail,
      );
      expect(
        decideStalledAction(nativeStatus: TaskStatus.canceled, attempts: 3),
        StalledAction.fail,
      );
    });
  });

  group('stale-aware batch state', () {
    const now = 10 * 60 * 1000;

    test('recent activity is not stalled', () {
      final b = _batch('a', [_job('a0', at: now - 5000)]);
      expect(b.isStalledAt(now), isFalse);
    });

    test('silence beyond the window is stalled', () {
      final b = _batch('a', [_job('a0', at: now - kStalledBatchAgeMs - 1)]);
      expect(b.isStalledAt(now), isTrue);
    });

    test('terminal batch is never stalled', () {
      final b = _batch('a', [_job('a0', state: JobState.done, at: 1)]);
      expect(b.isStalledAt(now), isFalse);
    });

    test('old snapshot without job timestamps falls back to updatedAt', () {
      final fresh = _batch('a', [_job('a0')], updatedAt: now - 1000);
      final old = _batch('b', [_job('b0')], updatedAt: 1000);
      expect(fresh.isStalledAt(now), isFalse);
      expect(old.isStalledAt(now), isTrue);
    });

    test('hasActiveDownloads ignores stalled batches', () {
      final mgr = DownloadManager.instance..clearBatchesForTesting();
      final real = DateTime.now().millisecondsSinceEpoch;
      mgr.setBatchForTesting(
        _batch('stuck', [_job('s0', at: real - kStalledBatchAgeMs - 5000)]),
      );
      expect(mgr.hasActiveDownloads, isFalse);
      expect(mgr.unfinishedBatches, hasLength(1));

      mgr.setBatchForTesting(_batch('live', [_job('l0', at: real)]));
      expect(mgr.hasActiveDownloads, isTrue);
      mgr.clearBatchesForTesting();
    });
  });

  group('mergeBatchViews', () {
    test('own batch wins over snapshot copy and newest comes first', () {
      final ownB = _batch('x', [_job('x0')], updatedAt: 300);
      final snapX = _batch('x', [_job('x0')], updatedAt: 100);
      final snapY = _batch('y', [_job('y0')], updatedAt: 200);
      final merged = mergeBatchViews([ownB], [snapX, snapY]);
      expect(merged.map((b) => b.batchId), ['x', 'y']);
      expect(identical(merged.first, ownB), isTrue);
    });
  });

  group('snapshot', () {
    test('lastProgressAt survives a round trip', () {
      final b = _batch('r', [_job('r0', at: 4242)]);
      final back = DownloadBatch.fromJson(b.toJson());
      expect(back.jobs.single.lastProgressAt, 4242);
    });

    test('copyOwnedBy takes the batch over and clears settledBy', () {
      final b = _batch('c', [_job('c0')])..settledBy = 'main';
      final mine = b.copyOwnedBy(DownloadBatch.sourceBackground);
      expect(mine.source, DownloadBatch.sourceBackground);
      expect(mine.settledBy, isNull);
    });
  });
}
