import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const downloaderChannel = MethodChannel('com.bbflight.background_downloader');
  const downloaderBgChannel = MethodChannel('com.bbflight.background_downloader.background');

  late Directory tempDir;
  late ResumableDownloadStore store;
  final Map<String, ResumeData> mockResumeData = {};
  final Map<String, TaskRecord> mockRecords = {};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, (call) async => null);

    HttpOverrides.global = null;
    SiteRegistry.useBuiltin();
    DownloadClaims.resetForTesting();
    mockResumeData.clear();
    mockRecords.clear();
    tempDir = await Directory.systemTemp.createTemp('v112_build77_test_');
    store = ResumableDownloadStore.instance;
    store.overrideDirectory = tempDir;
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    NetworkStatus.instance.setOnlineForTesting(true);

    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.getResumeDataForTesting = (id) async => mockResumeData[id];
    DownloadManager.instance.setResumeDataForTesting = (rd) async {
      mockResumeData[rd.task.taskId] = rd;
    };
    DownloadManager.instance.removeResumeDataForTesting = (id) async {
      mockResumeData.remove(id);
    };
    DownloadManager.instance.recordForIdForTesting = (id) async => mockRecords[id];
    DevLog.resetRecentForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);

    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.getResumeDataForTesting = null;
    DownloadManager.instance.setResumeDataForTesting = null;
    DownloadManager.instance.removeResumeDataForTesting = null;
    DownloadManager.instance.taskForIdForTesting = null;
    DownloadManager.instance.pauseForTesting = null;
    DownloadManager.instance.resumeForTesting = null;
    DownloadManager.instance.enqueueForTesting = null;
    DownloadManager.instance.cancelTaskForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;

    SiteRegistry.useBuiltin();
    store.overrideDirectory = null;
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('v1.12 build 77: First-round task pause and resume (Item A3)', () {
    test('A3.1: first-round download (status 200) pause and continue resumes same taskId and from_bytes', () async {
      // 1. First-round job: starts fresh from enqueue, NO pre-injected resumeTempPath or resumeStartByte
      final job = DownloadJob(
        key: 'a31-job',
        label: 'video',
        itemIndex: 0,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/first_round_test.mp4'],
        filename: 'first_round_test.mp4',
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.queued;
      expect(job.resumeTempPath, isNull);
      expect(job.resumeStartByte, isNull);

      final batch = DownloadBatch(
        batchId: 'a31-first-round-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/12345',
        platform: 'x',
        postId: 'a31-post-12345',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      // Plugin allocates random temp file in cache directory (plugin-managed location)
      final pluginCacheDir = Directory('${tempDir.path}/cache');
      await pluginCacheDir.create(recursive: true);
      final pluginTempFile = File('${pluginCacheDir.path}/com.bbflight.background_downloader_random98765');
      final raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(45 * 1024 * 1024); // 45MB downloaded in first round (status 200)
      await raf.close();

      // Enqueue attempt for first round
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_start');
      final firstRoundTaskId = job.currentTaskId!;
      expect(firstRoundTaskId, contains('-r1'));

      // Track subsequent enqueue calls (should be none)
      final enqueueCalls = <String>[];
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        enqueueCalls.add(j.currentTaskId ?? j.key);
      };

      final firstTask = DownloadTask(
        taskId: firstRoundTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async {
        if (id == firstRoundTaskId) return firstTask;
        return null;
      };

      // Simulate plugin pause: plugin saves ResumeData pointing to its internal temp file
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(
          firstTask,
          pluginTempFile.path,
          45 * 1024 * 1024,
          'etag-45mb',
        );
        mockRecords[t.taskId] = TaskRecord(firstTask, TaskStatus.paused, 45 / 500, 45 * 1024 * 1024);
        return true;
      };

      final resumedTaskIds = <String>[];
      final resumedStartBytes = <int>[];
      DownloadManager.instance.resumeForTesting = (t) async {
        resumedTaskIds.add(t.taskId);
        final rd = mockResumeData[t.taskId];
        resumedStartBytes.add(rd?.requiredStartByte ?? 0);
        return true;
      };

      // 2. User pauses batch
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);

      // Verify pause_resume_data log was written with present=yes and actual temp_size
      final recentLogs = DevLog.recentLines(50);
      final pauseLog = recentLogs.firstWhere((l) => l.contains('pause_resume_data') && l.contains(firstRoundTaskId));
      expect(pauseLog, contains('present=yes'));
      expect(pauseLog, contains('temp_size=47185920'));
      expect(pauseLog, contains('temp_exists=true'));

      // 3. User taps continue (resumeBatch)
      await DownloadManager.instance.resumeBatch(batch);

      // Verify: restored the exact same taskId, from_bytes equals downloaded amount before pause
      expect(resumedTaskIds.length, 1);
      expect(resumedTaskIds.first, firstRoundTaskId, reason: 'Must resume exact same taskId without new round');
      expect(resumedStartBytes.first, 45 * 1024 * 1024, reason: 'from_bytes must equal partial bytes on disk');
      expect(job.currentTaskId, firstRoundTaskId, reason: 'No new round (-r2) should be created');
      expect(enqueueCalls, isEmpty, reason: 'Must not call enqueue from 0 or run preflight');
    });

    test('A3.2: first-round pause -> continue -> pause -> continue 3 consecutive cycles', () async {
      final job = DownloadJob(
        key: 'a32-job',
        label: 'video',
        itemIndex: 0,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/first_round_3cycle.mp4'],
        filename: 'first_round_3cycle.mp4',
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.queued;

      final batch = DownloadBatch(
        batchId: 'a32-3cycle-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/12345',
        platform: 'x',
        postId: 'a32-post-12345',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      // Plugin temporary file
      final pluginCacheDir = Directory('${tempDir.path}/cache');
      await pluginCacheDir.create(recursive: true);
      final pluginTempFile = File('${pluginCacheDir.path}/com.bbflight.background_downloader_random11111');

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_start');
      final targetTaskId = job.currentTaskId!;

      final enqueueCalls = <String>[];
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        enqueueCalls.add(j.currentTaskId ?? j.key);
      };

      final task = DownloadTask(
        taskId: targetTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async => id == targetTaskId ? task : null;

      final resumedTaskIds = <String>[];
      final resumedStartBytes = <int>[];
      DownloadManager.instance.resumeForTesting = (t) async {
        resumedTaskIds.add(t.taskId);
        final rd = mockResumeData[t.taskId];
        resumedStartBytes.add(rd?.requiredStartByte ?? 0);
        return true;
      };

      // Cycle 1: 50MB
      var raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(50 * 1024 * 1024);
      await raf.close();
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(task, pluginTempFile.path, 50 * 1024 * 1024, 'etag-c1');
        mockRecords[t.taskId] = TaskRecord(task, TaskStatus.paused, 50 / 500, 50 * 1024 * 1024);
        return true;
      };
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, targetTaskId);
      expect(resumedStartBytes.last, 50 * 1024 * 1024);

      // Cycle 2: grows to 150MB
      raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(150 * 1024 * 1024);
      await raf.close();
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(task, pluginTempFile.path, 150 * 1024 * 1024, 'etag-c2');
        mockRecords[t.taskId] = TaskRecord(task, TaskStatus.paused, 150 / 500, 150 * 1024 * 1024);
        return true;
      };
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, targetTaskId);
      expect(resumedStartBytes.last, 150 * 1024 * 1024);

      // Cycle 3: grows to 300MB
      raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(300 * 1024 * 1024);
      await raf.close();
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(task, pluginTempFile.path, 300 * 1024 * 1024, 'etag-c3');
        mockRecords[t.taskId] = TaskRecord(task, TaskStatus.paused, 300 / 500, 300 * 1024 * 1024);
        return true;
      };
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, targetTaskId);
      expect(resumedStartBytes.last, 300 * 1024 * 1024);

      // Verify all 3 cycles retained the exact same taskId without new rounds
      expect(resumedTaskIds, [targetTaskId, targetTaskId, targetTaskId]);
      expect(resumedStartBytes, [50 * 1024 * 1024, 150 * 1024 * 1024, 300 * 1024 * 1024]);
      expect(job.currentTaskId, targetTaskId);
      expect(enqueueCalls, isEmpty);
    });

    test('A3.3: first-round pause -> network disconnect -> reconnect and continue', () async {
      final job = DownloadJob(
        key: 'a33-job',
        label: 'video',
        itemIndex: 0,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/first_round_net_test.mp4'],
        filename: 'first_round_net_test.mp4',
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.queued;

      final batch = DownloadBatch(
        batchId: 'a33-net-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/12345',
        platform: 'x',
        postId: 'a33-post-12345',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      final pluginCacheDir = Directory('${tempDir.path}/cache');
      await pluginCacheDir.create(recursive: true);
      final pluginTempFile = File('${pluginCacheDir.path}/com.bbflight.background_downloader_random22222');
      final raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(60 * 1024 * 1024); // 60MB
      await raf.close();

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_start');
      final targetTaskId = job.currentTaskId!;

      final task = DownloadTask(
        taskId: targetTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async => id == targetTaskId ? task : null;
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(task, pluginTempFile.path, 60 * 1024 * 1024, 'etag-60mb');
        mockRecords[t.taskId] = TaskRecord(task, TaskStatus.paused, 60 / 500, 60 * 1024 * 1024);
        return true;
      };

      final resumedTaskIds = <String>[];
      final resumedStartBytes = <int>[];
      DownloadManager.instance.resumeForTesting = (t) async {
        resumedTaskIds.add(t.taskId);
        final rd = mockResumeData[t.taskId];
        resumedStartBytes.add(rd?.requiredStartByte ?? 0);
        return true;
      };

      // 1. Pause
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);

      // 2. Network disconnects while paused
      NetworkStatus.instance.setOnlineForTesting(false);

      // 3. Network reconnects
      NetworkStatus.instance.setOnlineForTesting(true);

      // 4. User clicks continue
      await DownloadManager.instance.resumeBatch(batch);

      // Verify same task resumed from 60MB
      expect(resumedTaskIds.length, 1);
      expect(resumedTaskIds.first, targetTaskId);
      expect(resumedStartBytes.first, 60 * 1024 * 1024);
      expect(job.currentTaskId, targetTaskId);
    });

    test('A3.4: first-round pause -> app killed -> reopen and continue', () async {
      final job = DownloadJob(
        key: 'a34-job',
        label: 'video',
        itemIndex: 0,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/first_round_kill_test.mp4'],
        filename: 'first_round_kill_test.mp4',
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.queued;

      final batch = DownloadBatch(
        batchId: 'a34-kill-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/12345',
        platform: 'x',
        postId: 'a34-post-12345',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      final pluginCacheDir = Directory('${tempDir.path}/cache');
      await pluginCacheDir.create(recursive: true);
      final pluginTempFile = File('${pluginCacheDir.path}/com.bbflight.background_downloader_random33333');
      final raf = await pluginTempFile.open(mode: FileMode.write);
      await raf.truncate(80 * 1024 * 1024); // 80MB
      await raf.close();

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_start');
      final targetTaskId = job.currentTaskId!;

      final task = DownloadTask(
        taskId: targetTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async => id == targetTaskId ? task : null;
      DownloadManager.instance.pauseForTesting = (t) async {
        mockResumeData[t.taskId] = ResumeData(task, pluginTempFile.path, 80 * 1024 * 1024, 'etag-80mb');
        mockRecords[t.taskId] = TaskRecord(task, TaskStatus.paused, 80 / 500, 80 * 1024 * 1024);
        return true;
      };

      // 1. Pause
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      expect(job.resumeTempPath, pluginTempFile.path);

      // Serialize batch as if saved to disk before app kill
      final batchJson = jsonEncode(batch.toJson());

      // 2. Simulate App Killed: reset DownloadManager memory batches
      DownloadManager.instance.clearBatchesForTesting();

      // Restore batch from JSON (cold start load)
      final restoredBatch = DownloadBatch.fromJson(jsonDecode(batchJson) as Map<String, dynamic>);
      DownloadManager.instance.setBatchForTesting(restoredBatch);
      final restoredJob = restoredBatch.jobs.first;
      expect(restoredJob.state, JobState.paused);
      expect(restoredJob.currentTaskId, targetTaskId);
      expect(restoredJob.resumeTempPath, pluginTempFile.path);

      final resumedTaskIds = <String>[];
      final resumedStartBytes = <int>[];
      DownloadManager.instance.resumeForTesting = (t) async {
        resumedTaskIds.add(t.taskId);
        final rd = mockResumeData[t.taskId];
        resumedStartBytes.add(rd?.requiredStartByte ?? 0);
        return true;
      };

      // 3. User taps continue after reopen
      await DownloadManager.instance.resumeBatch(restoredBatch);

      // Verify same taskId resumed from 80MB
      expect(resumedTaskIds.length, 1);
      expect(resumedTaskIds.first, targetTaskId);
      expect(resumedStartBytes.first, 80 * 1024 * 1024);
      expect(restoredJob.currentTaskId, targetTaskId);
    });
  });
}
