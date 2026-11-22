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
    tempDir = await Directory.systemTemp.createTemp('v112_build76_test_');
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
    DevLog.resetRecentForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);

    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.getResumeDataForTesting = null;
    DownloadManager.instance.setResumeDataForTesting = null;
    DownloadManager.instance.removeResumeDataForTesting = null;
    DownloadManager.instance.taskForIdForTesting = null;
    DownloadManager.instance.pauseForTesting = null;
    DownloadManager.instance.resumeForTesting = null;
    DownloadManager.instance.enqueueForTesting = null;
    DownloadManager.instance.cancelTaskForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.downloaderStartForTesting = null;

    SiteRegistry.useBuiltin();
    store.overrideDirectory = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('v1.12 build 76: Resume from disk temporary file and pause/resume same task', () {
    // A3. 测试：同一下载连续「暂停 → 继续」3 次，每次 from_bytes 等于暂停时的已下载量，没有 enqueue from_bytes=0；最终文件完整。
    test('A3: same download paused and resumed 3 consecutive times retains same taskId and from_bytes', () async {
      final job = DownloadJob(
        key: 'a3-pause-resume-job',
        label: 'video',
        filename: 'a3_video.mp4',
        urls: ['https://video.twimg.com/a3_test_video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.active;
      job.currentTaskId = job.key;

      final batch = DownloadBatch(
        batchId: 'a3-pause-resume-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/12345',
        platform: 'x',
        postId: 'a3-post-12345',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      final tempPartFile = File('${tempDir.path}/${downloadTempDirectory(batch.batchId, job.key)}/${job.filename}');
      await tempPartFile.parent.create(recursive: true);
      job.resumeTempPath = tempPartFile.path;

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async {
        if (id == job.key) return task;
        return null;
      };

      DownloadManager.instance.pauseForTesting = (t) async {
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

      final enqueueCalls = <String>[];
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        enqueueCalls.add(j.currentTaskId ?? j.key);
      };

      // Cycle 1: 100MB
      final raf1 = await tempPartFile.open(mode: FileMode.write);
      await raf1.truncate(100 * 1024 * 1024);
      await raf1.close();
      job.progress = 100 / 500;

      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, job.key, reason: 'Resume must target the exact same taskId');
      expect(resumedStartBytes.last, 100 * 1024 * 1024);
      expect(job.currentTaskId, job.key, reason: 'No new round (-rN) should be created');

      // Cycle 2: 250MB
      final raf2 = await tempPartFile.open(mode: FileMode.write);
      await raf2.truncate(250 * 1024 * 1024);
      await raf2.close();
      job.progress = 250 / 500;

      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, job.key);
      expect(resumedStartBytes.last, 250 * 1024 * 1024);
      expect(job.currentTaskId, job.key);

      // Cycle 3: 400MB
      final raf3 = await tempPartFile.open(mode: FileMode.write);
      await raf3.truncate(400 * 1024 * 1024);
      await raf3.close();
      job.progress = 400 / 500;

      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      await DownloadManager.instance.resumeBatch(batch);
      expect(resumedTaskIds.last, job.key);
      expect(resumedStartBytes.last, 400 * 1024 * 1024);
      expect(job.currentTaskId, job.key);

      // Verify no enqueue calls from 0 occurred across all 3 pause-resume cycles
      expect(enqueueCalls, isEmpty, reason: 'No enqueue from 0 should occur when resuming paused task');
      expect(resumedTaskIds.length, 3);
      expect(resumedStartBytes, [100 * 1024 * 1024, 250 * 1024 * 1024, 400 * 1024 * 1024]);
    });

    // B6.1: 记录大于文件：按文件长度续传成功，写日志 resume_data_ahead record=… file=…
    test('B6.1: recorded start byte ahead of physical file truncates to physical size and logs resume_data_ahead', () async {
      final job = DownloadJob(
        key: 'b61-job',
        label: 'video',
        filename: 'b61_video.mp4',
        urls: ['https://video.twimg.com/b61.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 1000 * 1024 * 1024;
      job.currentTaskId = '${job.key}-r1';
      job.resumeStartByte = 231158131; // Stale higher recorded start byte

      final batch = DownloadBatch(
        batchId: 'b61-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/b61',
        platform: 'x',
        postId: 'b61-post',
        jobs: [job],
      );
      DownloadManager.instance.setBatchForTesting(batch);

      final tempPartFile = File('${tempDir.path}/${downloadTempDirectory(batch.batchId, job.key)}/${job.filename}');
      await tempPartFile.parent.create(recursive: true);
      final raf = await tempPartFile.open(mode: FileMode.write);
      await raf.truncate(207810931); // Physical file has only 207810931 bytes
      await raf.close();
      job.resumeTempPath = tempPartFile.path;

      final task = DownloadTask(
        taskId: job.currentTaskId!,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      mockResumeData[job.currentTaskId!] = ResumeData(
        task,
        tempPartFile.path,
        231158131,
        '"b61-etag"',
      );

      int? resumedStartByte;
      DownloadManager.instance.resumeForTesting = (t) async {
        final rd = mockResumeData[t.taskId];
        resumedStartByte = rd?.requiredStartByte;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumedStartByte, 207810931, reason: 'Resume start byte must equal physical file size');
      expect(job.resumeStartByte, 207810931);

      final recent = DevLog.recentLines(50);
      expect(
        recent.any((l) => l.contains('resume_data_ahead') && l.contains('record=231158131') && l.contains('file=207810931')),
        isTrue,
        reason: 'Must log resume_data_ahead when record > file',
      );
    });

    // B6.2: 先暂停、再从 0 重下、再断网恢复（复现真机序列）：按实际文件长度续传，完成
    test('B6.2: reproduce device sequence: pause -> restart from 0 -> disconnect -> recover from disk length', () async {
      final job = DownloadJob(
        key: 'b62-job',
        label: 'video',
        filename: 'b62_video.mp4',
        urls: ['https://video.twimg.com/b62.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 1000 * 1024 * 1024;
      job.currentTaskId = job.key;

      final batch = DownloadBatch(
        batchId: 'b62-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/b62',
        platform: 'x',
        postId: 'b62-post',
        jobs: [job],
      );
      DownloadManager.instance.setBatchForTesting(batch);

      final tempPartFile = File('${tempDir.path}/${downloadTempDirectory(batch.batchId, job.key)}/${job.filename}');
      await tempPartFile.parent.create(recursive: true);
      job.resumeTempPath = tempPartFile.path;

      // 1. Initial download reaches 231158131 bytes, then paused
      final raf1 = await tempPartFile.open(mode: FileMode.write);
      await raf1.truncate(231158131);
      await raf1.close();
      job.resumeStartByte = 231158131;
      job.state = JobState.paused;

      // 2. Restart from 0 occurs (e.g. size mismatch or clean restart)
      // File is deleted/restarted, resume state is cleared
      await tempPartFile.delete();
      final updateMismatch = TaskStatusUpdate(
        DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        TaskStatus.failed,
        TaskResumeException('size_mismatch'),
      );
      await DownloadManager.instance.taskFailureForTesting(batch, job, updateMismatch);

      // Verify resume records wiped
      expect(job.resumeStartByte, isNull);
      expect(job.progress, 0.0);

      // 3. New download starts from 0, downloads 207810931 bytes, then disconnects
      final raf2 = await tempPartFile.open(mode: FileMode.write);
      await raf2.truncate(207810931);
      await raf2.close();
      job.resumeTempPath = tempPartFile.path;

      final updateDisconnect = TaskStatusUpdate(
        DownloadTask(taskId: job.currentTaskId ?? job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        TaskStatus.failed,
        TaskConnectionException('SocketException: Software caused connection abort'),
      );
      await DownloadManager.instance.taskFailureForTesting(batch, job, updateDisconnect);

      // 4. 断网恢复: start byte must be exactly 207810931 (the actual file length on disk)
      expect(job.resumeStartByte, 207810931, reason: 'After disconnect, resume start byte must be 207810931 from disk');

      int? resumedFromBytes;
      DownloadManager.instance.resumeForTesting = (t) async {
        final rd = mockResumeData[t.taskId];
        resumedFromBytes = rd?.requiredStartByte;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);
      expect(resumedFromBytes, 207810931, reason: 'Resume must request exactly 207810931 bytes');
    });

    // B6.3: 从 0 重下后续传记录被清空
    test('B6.3: restart from zero completely clears resume records from job, store and plugin', () async {
      final job = DownloadJob(
        key: 'b63-job',
        label: 'video',
        filename: 'b63_video.mp4',
        urls: ['https://video.twimg.com/b63.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.currentTaskId = '${job.key}-r1';
      job.resumeStartByte = 50 * 1024 * 1024;
      job.resumeTempPath = '${tempDir.path}/b63.tmp';
      job.resumeEtag = '"b63-etag"';
      job.progress = 0.1;

      final batch = DownloadBatch(
        batchId: 'b63-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/b63',
        platform: 'x',
        postId: 'b63-post',
        jobs: [job],
      );

      final task = DownloadTask(taskId: job.currentTaskId!, url: job.urls.first);
      mockResumeData[job.currentTaskId!] = ResumeData(task, job.resumeTempPath!, 50 * 1024 * 1024, job.resumeEtag);

      // Trigger restart from 0 via size_mismatch
      final update = TaskStatusUpdate(task, TaskStatus.failed, TaskResumeException('size_mismatch'));
      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      expect(job.resumeStartByte, isNull);
      expect(job.resumeTempPath, isNull);
      expect(job.resumeEtag, isNull);
      expect(job.progress, 0.0);
      expect(mockResumeData[job.currentTaskId!], isNull);
    });

    // B6.4: 连续 resume_failed 不会无限重试
    test('B6.4: consecutive resume_failed failures (>2) transitions to interrupted without endless retry', () async {
      final job = DownloadJob(
        key: 'b64-job',
        label: 'video',
        filename: 'b64_video.mp4',
        urls: ['https://video.twimg.com/b64.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.currentTaskId = job.key;

      final batch = DownloadBatch(
        batchId: 'b64-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/b64',
        platform: 'x',
        postId: 'b64-post',
        jobs: [job],
      );
      DownloadManager.instance.setBatchForTesting(batch);

      final tempPartFile = File('${tempDir.path}/${downloadTempDirectory(batch.batchId, job.key)}/${job.filename}');
      await tempPartFile.parent.create(recursive: true);
      final raf = await tempPartFile.open(mode: FileMode.write);
      await raf.truncate(50 * 1024 * 1024);
      await raf.close();
      job.resumeTempPath = tempPartFile.path;

      final task = DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId);

      // Failure 1: resume_failed
      final fail1 = TaskStatusUpdate(task, TaskStatus.failed, TaskResumeException('resume_failed'));
      await DownloadManager.instance.taskFailureForTesting(batch, job, fail1);
      expect(job.consecutiveFailCount, 1);
      expect(job.lastFailReason, 'resume_failed');

      // Failure 2: resume_failed again
      final fail2 = TaskStatusUpdate(task, TaskStatus.failed, TaskResumeException('resume_failed'));
      await DownloadManager.instance.taskFailureForTesting(batch, job, fail2);
      expect(job.consecutiveFailCount, 2);

      // Failure 3: resume_failed a 3rd time (> 2)
      final fail3 = TaskStatusUpdate(task, TaskStatus.failed, TaskResumeException('resume_failed'));
      await DownloadManager.instance.taskFailureForTesting(batch, job, fail3);
      expect(job.consecutiveFailCount, 3);
      expect(job.state, JobState.paused);
      expect(job.error, '已中断，点继续');
    });
  });
}
