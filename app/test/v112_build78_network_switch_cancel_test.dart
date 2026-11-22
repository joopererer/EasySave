// Copyright 2026 EasySave. All rights reserved.
// v1.12 build 78: Network switch cancel fix & internal interrupt handling tests (Item A4)

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
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

class _FakePaths extends PathProviderPlatform {
  final String root;
  _FakePaths(this.root);
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const downloaderChannel = MethodChannel('com.bbflight.background_downloader');
  const downloaderBgChannel = MethodChannel('com.bbflight.background_downloader.background');

  late Directory tempDir;
  late ResumableDownloadStore store;
  late PathProviderPlatform originalPathProvider;
  final Map<String, ResumeData> mockResumeData = {};
  final Map<String, TaskRecord> mockRecords = {};

  void writeMockMp4(File file) {
    file.parent.createSync(recursive: true);
    final fixture = File('../docs/provenance-spec/test-vectors/mp4-no-xmp.mp4');
    if (fixture.existsSync()) {
      fixture.copySync(file.path);
    } else {
      final bytes = List<int>.filled(10000, 0);
      bytes[3] = 0x18;
      bytes[4] = 0x66; // 'f'
      bytes[5] = 0x74; // 't'
      bytes[6] = 0x79; // 'y'
      bytes[7] = 0x70; // 'p'
      file.writeAsBytesSync(bytes);
    }
  }

  setUpAll(() {
    originalPathProvider = PathProviderPlatform.instance;
  });

  tearDownAll(() {
    PathProviderPlatform.instance = originalPathProvider;
  });

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
    tempDir = await Directory.systemTemp.createTemp('v112_build78_test_');
    PathProviderPlatform.instance = _FakePaths(tempDir.path);
    store = ResumableDownloadStore.instance;
    store.overrideDirectory = tempDir;
    DownloadManager.instance.tempRootForTesting = () async => tempDir;

    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.gallerySaveForTesting = (path, job) async => (
      mediaId: 'test-media-id',
      title: job.filename,
      relativePath: 'Movies/EasySave',
    );
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
    DownloadManager.instance.gallerySaveForTesting = null;
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

  group('v1.12 build 78: Network switch cancel & internal interrupt (Item A4)', () {
    test('A4.1: Download starts, network switches 4G to Wi-Fi -> task is not canceled, completes', () async {
      // 1. Initial network state is cellular (4G)
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'cellular');
      DownloadManager.instance.onNetworkChangedForTesting();

      final job = DownloadJob(
        key: 'a41-job',
        label: 'video',
        itemIndex: 1,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/net_switch_test.mp4'],
        filename: 'net_switch_test.mp4',
      );
      job.expectedBytes = 100 * 1024 * 1024;
      job.state = JobState.queued;

      final batch = DownloadBatch(
        batchId: 'a41-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/78001',
        platform: 'x',
        postId: 'a41-post-78001',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      // Start the download
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'user_start');
      final taskId = job.currentTaskId!;
      expect(taskId, contains('-r1'));
      expect(job.state, equals(JobState.queued));

      final runningTask = DownloadTask(
        taskId: taskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      // Update task to running
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(runningTask, TaskStatus.running),
      );
      expect(job.state, equals(JobState.active));

      // 2. Network switches from cellular to Wi-Fi shortly after start
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'wifi');
      DownloadManager.instance.onNetworkChangedForTesting();

      final logs = DevLog.recentLines(500);
      // Log must observe the network change
      expect(logs.any((l) => l.contains('network_change from=cellular to=wifi action=observe')), isTrue);
      // Log must NOT contain cancel_call source=internal_interrupt
      expect(logs.any((l) => l.contains('cancel_call') && l.contains('source=internal_interrupt')), isFalse);

      // Task is not canceled and remains active
      expect(job.state, equals(JobState.active));
      expect(job.userCancelRequested, isFalse);

      // 3. Complete download
      final filePath = await runningTask.filePath();
      writeMockMp4(File(filePath));

      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(runningTask, TaskStatus.complete),
      );
      await waitFor(() => job.state == JobState.done, description: 'job done after complete');

      final finalLogs = DevLog.recentLines(500);
      expect(finalLogs.any((l) => l.contains('batch_settle') && l.contains('all_completed') && l.contains('files=1')), isTrue);
      expect(job.state, equals(JobState.done));
    });

    test('A4.2: Simulated internal cancellation with NO downloaded data -> auto re-enqueues from scratch, never logs CONTENT or final_fail', () async {
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'wifi');
      DownloadManager.instance.onNetworkChangedForTesting();

      final job = DownloadJob(
        key: 'a42-job',
        label: 'video',
        itemIndex: 1,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/internal_cancel_nodata.mp4'],
        filename: 'internal_cancel_nodata.mp4',
      );
      job.expectedBytes = 100 * 1024 * 1024;
      job.state = JobState.queued;
      job.attempts = 0;

      final batch = DownloadBatch(
        batchId: 'a42-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/78002',
        platform: 'x',
        postId: 'a42-post-78002',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      // First attempt
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'user_start');
      expect(job.attempts, equals(1));
      final task1Id = job.currentTaskId!;

      final task1 = DownloadTask(
        taskId: task1Id,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      // Transition to running
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(task1, TaskStatus.running),
      );
      expect(job.state, equals(JobState.active));

      // Simulate plugin reporting TaskStatus.canceled with NO downloaded data (partialBytes == 0)
      // and NO user cancellation requested
      expect(job.userCancelRequested, isFalse);
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(task1, TaskStatus.canceled),
      );
      await waitFor(() => job.attempts >= 2, description: 'job auto-retry attempt 2');

      final logs = DevLog.recentLines(500);

      // Must log auto_retry reason=interrupted from_bytes=0 attempt=2/...
      expect(logs.any((l) => l.contains('auto_retry reason=interrupted from_bytes=0 attempt=2/')), isTrue);

      // Must NOT contain reason=CONTENT
      expect(logs.any((l) => l.contains('reason=CONTENT')), isFalse);

      // Must NOT contain temp_cleanup reason=final_fail
      expect(logs.any((l) => l.contains('temp_cleanup reason=final_fail')), isFalse);

      // Job must have automatically re-enqueued for attempt 2
      expect(job.attempts, equals(2));
      final task2Id = job.currentTaskId!;
      expect(task2Id, isNot(equals(task1Id)));

      final task2 = DownloadTask(
        taskId: task2Id,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      // Second attempt completes successfully
      final filePath = await task2.filePath();
      writeMockMp4(File(filePath));

      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(task2, TaskStatus.complete),
      );
      await waitFor(() => job.state == JobState.done, description: 'job done after 2nd complete');

      final finalLogs = DevLog.recentLines(500);
      expect(finalLogs.any((l) => l.contains('batch_settle') && l.contains('all_completed') && l.contains('files=1')), isTrue);
      expect(job.state, equals(JobState.done));
    });

    test('A4.3: Simulated internal cancellation WITH downloaded data -> resumes from breakpoint and completes', () async {
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'wifi');
      DownloadManager.instance.onNetworkChangedForTesting();

      final job = DownloadJob(
        key: 'a43-job',
        label: 'video',
        itemIndex: 1,
        isImage: false,
        urls: ['https://video.twimg.com/ext_tw_video/internal_cancel_withdata.mp4'],
        filename: 'internal_cancel_withdata.mp4',
      );
      job.expectedBytes = 100 * 1024 * 1024;
      job.state = JobState.queued;
      job.attempts = 0;

      final batch = DownloadBatch(
        batchId: 'a43-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/78003',
        platform: 'x',
        postId: 'a43-post-78003',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);

      // Prepare partial temp file with 25MB
      final partialBytes = 25 * 1024 * 1024;
      final tempFile = File('${tempDir.path}/partial_a43.tmp');
      final raf = await tempFile.open(mode: FileMode.write);
      await raf.truncate(partialBytes);
      await raf.close();

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'user_start');
      final initialTaskId = job.currentTaskId!;

      final initialTask = DownloadTask(
        taskId: initialTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      DownloadManager.instance.taskForIdForTesting = (id) async {
        if (id == initialTaskId) return initialTask;
        return null;
      };

      // Mock plugin resume data pointing to the 25MB temp file
      final resumeData = ResumeData(initialTask, tempFile.path, partialBytes, 'etag-78003');
      mockResumeData[initialTaskId] = resumeData;

      // Transition to running
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(initialTask, TaskStatus.running),
      );
      expect(job.state, equals(JobState.active));

      // Simulate plugin reporting TaskStatus.canceled with downloaded data and NO user cancellation
      expect(job.userCancelRequested, isFalse);
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(initialTask, TaskStatus.canceled),
      );
      await waitFor(() => job.state == JobState.paused, description: 'job paused after cancel with data');

      // Job should enter JobState.paused ("下载中断") preserving the temp file
      expect(job.state, equals(JobState.paused));
      expect(job.resumeStartByte, equals(partialBytes));
      expect(tempFile.existsSync(), isTrue);

      final logs = DevLog.recentLines(500);
      expect(logs.any((l) => l.contains('temp_cleanup reason=final_fail')), isFalse);
      expect(logs.any((l) => l.contains('reason=CONTENT')), isFalse);

      // Resume from breakpoint
      DownloadTask? resumedTask;
      DownloadManager.instance.resumeForTesting = (task) async {
        resumedTask = task;
        return true;
      };

      await DownloadManager.instance.resumeBatch(batch);
      final resumedTaskId = job.currentTaskId!;
      expect(resumedTaskId, contains('a43-job'));

      final taskToComplete = resumedTask ?? DownloadTask(
        taskId: resumedTaskId,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
        allowPause: true,
      );

      // Complete download
      final filePath = await taskToComplete.filePath();
      writeMockMp4(File(filePath));

      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(taskToComplete, TaskStatus.complete),
      );
      await waitFor(() => job.state == JobState.done, description: 'job done after resumed complete');

      final finalLogs = DevLog.recentLines(500);
      expect(finalLogs.any((l) => l.contains('batch_settle') && l.contains('all_completed') && l.contains('files=1')), isTrue);
      expect(job.state, equals(JobState.done));
    });
  });
}
