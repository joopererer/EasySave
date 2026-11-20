import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/network_status.dart';
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
  const notifyChannel = MethodChannel('dexterous.com/flutter/local_notifications');

  setUp(() async {
    HttpOverrides.global = null;
    SiteRegistry.useBuiltin();
    DownloadClaims.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    NetworkStatus.instance.resetForTesting();
    NetworkStatus.instance.setOnlineForTesting(true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, (call) async => true);

    tempDir = await Directory.systemTemp.createTemp('v112_b73_test_');
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    DownloadManager.owner = DownloadBatch.sourceMain;
    DownloadManager.instance.activeQueryRetryDelay = Duration.zero;
    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.contentLengthProbeForTesting = (j, u) async => 100000000;
    DownloadManager.instance.getResumeDataForTesting = (id) async => null;
    DownloadManager.instance.setResumeDataForTesting = (rd) async {};
    DownloadManager.instance.removeResumeDataForTesting = (id) async {};
    DownloadManager.instance.cancelTaskForTesting = (id) async {};
    DownloadManager.instance.recordForIdForTesting = (id) async => null;
    DownloadManager.instance.allRecordsForTesting = (group) async => [];
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();

    final db = await HistoryDb.instance();
    await db.clear();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, null);

    DevLog.resetRecentForTesting();
    DownloadManager.owner = DownloadBatch.sourceMain;
    DownloadManager.instance.activeQueryRetryDelay = const Duration(seconds: 30);
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.contentLengthProbeForTesting = null;
    DownloadManager.instance.enqueueForTesting = null;
    DownloadManager.instance.resumeForTesting = null;
    DownloadManager.instance.cancelTaskForTesting = null;
    DownloadManager.instance.getResumeDataForTesting = null;
    DownloadManager.instance.setResumeDataForTesting = null;
    DownloadManager.instance.removeResumeDataForTesting = null;
    DownloadManager.instance.clearBatchesForTesting();
    ResumableDownloadStore.instance.overrideDirectory = null;

    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createResumableBatch({
    String batchId = 'resumable-b73-1',
    int partialBytes = 25000000,
    int totalBytes = 100000000,
  }) {
    final job = DownloadJob(
      key: '$batchId-0',
      label: 'video',
      filename: 'large_video.mp4',
      urls: ['https://video.twimg.com/video.mp4'],
      isImage: false,
      itemIndex: 0,
    )
      ..expectedBytes = totalBytes
      ..progress = partialBytes / totalBytes
      ..resumeStartByte = partialBytes
      ..state = JobState.active
      ..currentTaskId = '$batchId-0-r1';

    final tempFile = File('${tempDir.path}/$batchId-0.tmp');
    tempFile.writeAsBytesSync(List.filled(partialBytes > 1024 ? 1024 : partialBytes, 0));
    job.resumeTempPath = tempFile.path;

    return DownloadBatch(
      batchId: batchId,
      album: 'EasySave',
      postUrl: 'https://x.com/user/status/123',
      platform: 'x',
      postId: '123',
      source: DownloadBatch.sourceMain,
      jobs: [job],
    );
  }

  group('v1.12 build 73: Item A - Resumable Cancel Protection & In-Flight Guard', () {
    test('A6.1: Internal cancel without user flag preserves temp file and transitions to paused', () async {
      final batch = createResumableBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      final task = DownloadTask(
        taskId: job.currentTaskId!,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      final resumeData = ResumeData(task, job.resumeTempPath!, job.resumeStartByte!, 'etag-123');
      DownloadManager.instance.getResumeDataForTesting = (id) async => resumeData;

      // Simulate plugin reporting TaskStatus.canceled without userCancelRequested
      expect(job.userCancelRequested, isFalse);
      DownloadManager.instance.taskUpdateForTesting(TaskStatusUpdate(task, TaskStatus.canceled));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Temp file should still exist
      final tempFile = File(job.resumeTempPath!);
      expect(tempFile.existsSync(), isTrue);

      // Job should NOT be canceled or failed; it must enter JobState.paused ("下载中断")
      expect(job.state, equals(JobState.paused));
      expect(batch.isTerminal, isFalse);

      // Verify no user_canceled temp_discard was logged
      final logs = DevLog.recentLines(500);
      expect(logs.any((m) => m.contains('temp_discard reason=user_canceled')), isFalse);
      expect(logs.any((m) => m.contains('cancel_call') && m.contains('source=internal_interrupt')), isTrue);
    });

    test('A6.2: User cancellation sets userCancelRequested, deletes temp file and logs source', () async {
      final batch = createResumableBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      final tempPath = job.resumeTempPath!;
      expect(File(tempPath).existsSync(), isTrue);

      // User initiates cancel
      await DownloadManager.instance.cancelJob(batch, job, source: 'queue_test');

      expect(job.userCancelRequested, isTrue);
      expect(job.state, equals(JobState.canceled));
      expect(File(tempPath).existsSync(), isFalse);

      final logs = DevLog.recentLines(500);
      expect(logs.any((m) => m.contains('temp_discard reason=user_canceled source=queue_test')), isTrue);
      expect(logs.any((m) => m.contains('cancel_call') && m.contains('source=queue_test')), isTrue);
    });

    test('A6.3: Concurrent auto_resume and network recovery skips duplicate in-flight resume', () async {
      final batch = createResumableBatch();
      final job = batch.jobs.first;
      job.state = JobState.paused;
      DownloadManager.instance.setBatchForTesting(batch);

      int enqueueCalls = 0;
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        enqueueCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      };

      // First enqueue starts
      final firstAttempt = DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'auto_resume');

      // Second enqueue arrives while first is in-flight
      final secondAttempt = DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'network_recovery');

      await Future.wait([firstAttempt, secondAttempt]);

      // Only one enqueue was performed; the other was skipped
      expect(enqueueCalls, equals(1));

      final logs = DevLog.recentLines(500);
      expect(logs.any((m) => m.contains('resume_skipped reason=in_flight source=network_recovery')), isTrue);
    });

    test('A6.4: Resume start byte catches up to larger on-disk temp file size', () async {
      const recordedStartByte = 6000000;
      const actualOnDiskSize = 8000000;

      final batch = createResumableBatch(
        partialBytes: recordedStartByte,
        totalBytes: 20000000,
      );
      final job = batch.jobs.first;
      job.state = JobState.paused;
      DownloadManager.instance.setBatchForTesting(batch);

      // Write temp file with actual larger length
      final tempFile = File(job.resumeTempPath!);
      final fileChannel = tempFile.openSync(mode: FileMode.write);
      fileChannel.truncateSync(actualOnDiskSize);
      fileChannel.closeSync();

      expect(tempFile.lengthSync(), equals(actualOnDiskSize));

      final task = DownloadTask(
        taskId: job.currentTaskId!,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      final oldResumeData = ResumeData(task, tempFile.path, recordedStartByte, 'etag-abc');
      ResumeData? savedResumeData;
      DownloadManager.instance.getResumeDataForTesting = (id) async => oldResumeData;
      DownloadManager.instance.setResumeDataForTesting = (rd) async => savedResumeData = rd;

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_start_byte');

      expect(resumeCalled, isTrue);
      // Effective start byte must be updated to the on-disk file size
      expect(job.resumeStartByte, equals(actualOnDiskSize));
      expect(savedResumeData?.requiredStartByte, equals(actualOnDiskSize));
    });
  });

  group('v1.12 build 73: Item B - Interrupted Status Copy', () {
    test('B3: Interrupted status text differentiates network wait, auto-retry, exhausted and user paused', () {
      final batch = createResumableBatch();
      final job = batch.jobs.first;

      // Case 1: Interrupted waiting for network
      job.state = JobState.paused;
      job.userPaused = false;
      job.error = '下载中断 · 等待网络';
      expect(batch.isPaused, isTrue);
      expect(batch.isUserPaused, isFalse);
      expect(batch.statusText, equals('下载中断 · 等待网络'));

      // Case 2: Auto-retry countdown
      job.error = '自动重试 2/5';
      expect(batch.statusText, equals('自动重试 2/5'));

      // Case 3: Retries exhausted
      job.error = '已中断，点继续';
      expect(batch.statusText, equals('已中断，点继续'));

      // Case 4: User paused explicitly
      job.userPaused = true;
      job.error = null;
      expect(batch.isUserPaused, isTrue);
      expect(batch.statusText, equals('已暂停'));
    });
  });

  group('v1.12 build 73: Item C - Fallback Option', () {
    test('C3: When manualResumeOnlyOnDisconnect is enabled, stops at "已中断，点继续" without auto-resume', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('manualResumeOnlyOnDisconnect', true);

      final batch = createResumableBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      final task = DownloadTask(
        taskId: job.currentTaskId!,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );
      final resumeData = ResumeData(task, job.resumeTempPath!, job.resumeStartByte!, 'etag-123');
      DownloadManager.instance.getResumeDataForTesting = (id) async => resumeData;

      // Simulate failure callback (e.g. connection abort)
      DownloadManager.instance.taskUpdateForTesting(TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskConnectionException('Software caused connection abort'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Job should be paused with copy "已中断，点继续"
      expect(job.state, equals(JobState.paused));
      expect(job.error, equals('已中断，点继续'));

      // Data is intact
      expect(File(job.resumeTempPath!).existsSync(), isTrue);

      // Now user manually resumes
      int resumeCount = 0;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCount++;
        return true;
      };

      await DownloadManager.instance.resumeBatch(batch);
      expect(resumeCount, equals(1));
      expect(job.userPaused, isFalse);
    });
  });
}
