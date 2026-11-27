import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  const downloaderChannel = MethodChannel('com.bbflight.background_downloader');
  const downloaderBgChannel = MethodChannel('com.bbflight.background_downloader.background');

  setUp(() async {
    HttpOverrides.global = null;
    SiteRegistry.useBuiltin();
    DownloadClaims.resetForTesting();
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, (call) async => null);

    tempDir = await Directory.systemTemp.createTemp('v112_b68_test_');
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.contentLengthProbeForTesting = (j, u) async => 100000000;
    DownloadManager.instance.allRecordsForTesting = (_) async => [];
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);

    DevLog.resetRecentForTesting();
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.resumeForTesting = null;
    DownloadManager.instance.getResumeDataForTesting = null;
    DownloadManager.instance.setResumeDataForTesting = null;
    DownloadManager.instance.removeResumeDataForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.contentLengthProbeForTesting = null;
    DownloadManager.instance.gallerySaveForTesting = null;
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    ResumableDownloadStore.instance.overrideDirectory = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  DownloadBatch createTestBatch({String batchId = 'test-batch-b68'}) {
    final job = DownloadJob(
      key: 'job_b68_1',
      itemIndex: 1,
      filename: 'video_1.mp4',
      label: 'video:mp4',
      isImage: false,
      urls: ['https://video.twimg.com/amplify_video/123/vid/720x1280/test.mp4'],
    )..expectedBytes = 50000000; // 50MB resumable
    final batch = DownloadBatch(
      batchId: batchId,
      platform: 'twitter',
      postId: 'post123',
      postUrl: 'https://x.com/user/status/123',
      authorName: 'user',
      title: 'test title',
      album: 'EasySave',
      jobs: [job],
    );
    return batch;
  }

  group('1c. Finishing stage lock blocks re-enqueue / resume from all sources', () {
    test('enqueue_blocked is logged when job isFinishing or completed', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      // 1. Finishing state
      job.isFinishing = true;
      job.currentTaskId = '${job.key}-r1';

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'manual_retry');
      expect(
        DevLog.recentLines(50).any((l) => l.contains('enqueue_blocked') && l.contains('reason=finishing') && l.contains('source=manual_retry')),
        isTrue,
        reason: 'finishing job must block manual_retry',
      );

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'network_retry');
      expect(
        DevLog.recentLines(50).any((l) => l.contains('enqueue_blocked') && l.contains('reason=finishing') && l.contains('source=network_retry')),
        isTrue,
        reason: 'finishing job must block network_retry',
      );

      // 2. Completed / saved state
      job.isFinishing = false;
      job.saved = true;
      job.state = JobState.done;

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'watchdog');
      expect(
        DevLog.recentLines(50).any((l) => l.contains('enqueue_blocked') && l.contains('reason=completed') && l.contains('source=watchdog')),
        isTrue,
        reason: 'completed job must block watchdog',
      );

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'reconcile_retry');
      expect(
        DevLog.recentLines(50).any((l) => l.contains('enqueue_blocked') && l.contains('reason=completed') && l.contains('source=reconcile_retry')),
        isTrue,
        reason: 'completed job must block reconcile',
      );
    });
  });

  group('2c. Task rounds increment taskId and drop stale updates', () {
    test('task round increments taskId and rejects older rounds with stale_update', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      // Mock resume/start
      DownloadManager.instance.resumeForTesting = (t) async => true;
      DownloadManager.instance.getResumeDataForTesting = (id) async => null;

      // First attempt -> round 1
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'round1');
      expect(job.round, 1);
      expect(job.currentTaskId, '${job.key}-r1');

      // Second attempt -> round 2
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'round2');
      expect(job.round, 2);
      expect(job.currentTaskId, '${job.key}-r2');

      // Now send a delayed callback for round 1 task
      final staleTask = DownloadTask(
        taskId: '${job.key}-r1',
        url: 'https://video.twimg.com/amplify_video/123/vid/720x1280/test.mp4',
        filename: 'video_1.mp4',
        group: batch.batchId,
      );
      final staleUpdate = TaskProgressUpdate(staleTask, 0.4);
      DownloadManager.instance.taskUpdateForTesting(staleUpdate);

      expect(
        DevLog.recentLines(50).any((l) => l.contains('stale_update') && l.contains('taskId=${job.key}-r1') && l.contains('status=progress')),
        isTrue,
        reason: 'old round update must be logged as stale_update and ignored',
      );
      expect(job.progress, isNot(0.4), reason: 'stale update must not modify job progress');

      // Send update for round 2 task -> processed normally
      final activeTask = DownloadTask(
        taskId: '${job.key}-r2',
        url: 'https://video.twimg.com/amplify_video/123/vid/720x1280/test.mp4',
        filename: 'video_1.mp4',
        group: batch.batchId,
      );
      final activeUpdate = TaskProgressUpdate(activeTask, 0.6);
      DownloadManager.instance.taskUpdateForTesting(activeUpdate);

      expect(job.progress, 0.6, reason: 'matching round update must be accepted');
    });
  });

  group('3b. Accurate preflight partial_bytes and need_bytes after pause', () {
    test('preflight reflects actual partial bytes from resume data and disk file', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      job.expectedBytes = 100000000; // 100MB
      job.resumeStartByte = 45000000; // 45MB downloaded
      DownloadManager.instance.setBatchForTesting(batch);

      // Verify that when storage check runs, partial_bytes=45000000 and need_bytes reflects remainder
      var enqueued = false;
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        enqueued = true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'preflight_test');
      expect(enqueued, isTrue);

      final preflightLog = DevLog.recentLines(50).firstWhere((l) => l.contains('preflight') && l.contains('partial_bytes=45000000'));
      expect(preflightLog, isNotNull);
      expect(preflightLog.contains('need_bytes='), isTrue);
      // need_bytes for (100MB - 45MB = 55MB) should be around 55MB (plus overhead), not 100MB!
      expect(preflightLog.contains('partial_bytes=45000000'), isTrue);
    });
  });

  group('4b. Finish timing metrics', () {
    test('logs finish_timing with all expected measurement fields upon batch completion', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      job.saved = true;
      job.state = JobState.done;
      job.downloadCompleteAt = DateTime.now().millisecondsSinceEpoch - 500;
      job.waitCompleteMs = 500;
      job.provenanceMs = 120;
      job.provenanceBytesWritten = 1000;
      job.importCopyMs = 80;
      job.importBytes = 1000;

      // Trigger terminal processing
      await DownloadManager.instance.afterTerminalForTesting(batch);

      expect(job.saved, isTrue);
      expect(
        DevLog.recentLines(50).any((l) =>
            l.contains('finish_timing') &&
            l.contains('wait_complete_ms=500') &&
            l.contains('provenance_ms=120') &&
            l.contains('provenance_bytes_written=1000') &&
            l.contains('import_copy_ms=80') &&
            l.contains('import_bytes=1000') &&
            l.contains('thread=bg') &&
            l.contains('history_ms=')),
        isTrue,
        reason: 'finish_timing log must contain all measured stages',
      );
    });
  });
}
