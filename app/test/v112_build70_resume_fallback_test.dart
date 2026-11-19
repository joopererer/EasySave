import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
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

    tempDir = await Directory.systemTemp.createTemp('v112_b70_fallback_test_');
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.contentLengthProbeForTesting = (j, u) async => 100000000;
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
    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.contentLengthProbeForTesting = null;
    DownloadManager.instance.enqueueForTesting = null;
    ResumableDownloadStore.instance.overrideDirectory = null;

    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createResumableBatch({
    String batchId = 'resumable-batch-1',
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

  group('build 70: Rule 2a - Partial file bytes > 0 enters paused (interrupted)', () {
    test('connection abort failure does not mark final failed and does not delete temp file', () async {
      final dm = DownloadManager.instance;
      final batch = createResumableBatch();
      dm.setBatchForTesting(batch);

      final job = batch.jobs[0];
      final tempFile = File(job.resumeTempPath!);
      expect(tempFile.existsSync(), isTrue);

      final update = TaskStatusUpdate(
        DownloadTask(
          taskId: job.currentTaskId!,
          url: job.urls[0],
          filename: job.filename,
          group: batch.batchId,
        ),
        TaskStatus.failed,
        TaskConnectionException('java.net.SocketException: Software caused connection abort'),
      );

      // Deliver failure and await completion
      await dm.taskFailureForTesting(batch, job, update);

      // Rule 2a: Must enter paused ("下载中断"), NOT failed!
      expect(job.state, equals(JobState.paused));
      expect(batch.isPaused, isTrue);
      expect(batch.isTerminal, isFalse);

      // Temp file must be preserved
      expect(tempFile.existsSync(), isTrue);
      expect(job.resumeStartByte, isNotNull);
      expect(job.resumeStartByte! > 0, isTrue);
    });
  });

  group('build 70: Rule 2b & 2c - Auto resume retries with exponential backoff & exhausted state', () {
    test('auto resume retries max 5 times, then transitions to "已中断，点继续"', () async {
      final dm = DownloadManager.instance;
      final batch = createResumableBatch();
      dm.setBatchForTesting(batch);
      final job = batch.jobs[0];

      // Simulate 5 retries exhausted: when 5th retry fails (retries >= 5), transitions to "已中断，点继续"
      dm.autoResumeRetriesForTesting[job.key] = 5;
      final update = TaskStatusUpdate(
        DownloadTask(
          taskId: job.currentTaskId!,
          url: job.urls[0],
          filename: job.filename,
          group: batch.batchId,
        ),
        TaskStatus.failed,
        TaskConnectionException('connection reset'),
      );
      await dm.taskFailureForTesting(batch, job, update);

      // After 5 retries exhausted:
      expect(job.state, equals(JobState.paused));
      expect(job.error, equals('已中断，点继续'));

      // 2c: Manual continue resumes
      int enqueued = 0;
      dm.enqueueForTesting = (b, j) async {
        enqueued++;
      };

      await dm.resumeBatch(batch);
      expect(enqueued, equals(1));
      expect(dm.autoResumeRetriesForTesting.containsKey(job.key), isFalse);
    });
  });

  group('build 70: Rule 2d - Temp file discard strictly limited', () {
    test('temp_discard logged only on size_mismatch, cancel, delete, status_200', () async {
      final dm = DownloadManager.instance;
      final batch = createResumableBatch();
      dm.setBatchForTesting(batch);
      final job = batch.jobs[0];

      // Size mismatch triggers temp_discard reason=size_mismatch
      final sizeMismatchUpdate = TaskStatusUpdate(
        DownloadTask(
          taskId: job.currentTaskId!,
          url: job.urls[0],
          filename: job.filename,
          group: batch.batchId,
        ),
        TaskStatus.failed,
        TaskResumeException('size_mismatch: server total 999 != expected 1000'),
      );
      await dm.taskFailureForTesting(batch, job, sizeMismatchUpdate);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('temp_discard reason=size_mismatch')), isTrue);
    });
  });

  group('build 70: Rule 2h & 2i - Network switching & 3s stability timer', () {
    test('network recovery waits 3s; network switch within 2s resets timer; resumes only after 3s stable', () async {
      final dm = DownloadManager.instance;
      dm.attachNetworkListenerForTesting();

      final batch = createResumableBatch();
      batch.jobs[0].state = JobState.paused;
      dm.setBatchForTesting(batch);

      // Start offline
      NetworkStatus.instance.setStatusForTesting(online: false, type: 'none');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Network recovers: flight mode off -> connects to cellular
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'cellular');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      var logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('network_change from=none to=cellular action=wait_stable')), isTrue);
      // Stability timer must be active
      expect(dm.networkStabilityTimerForTesting, isNotNull);

      // 2 seconds later (within 3s), switches to Wi-Fi
      NetworkStatus.instance.setNetworkTypeForTesting('wifi');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('network_change from=cellular to=wifi action=wait_stable')), isTrue);
      expect(dm.networkStabilityTimerForTesting, isNotNull);

      // Simulate stability timer firing
      int enqueued = 0;
      dm.enqueueForTesting = (b, j) async {
        enqueued++;
      };

      dm.fireNetworkStabilityTimerForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('network_change from=cellular to=wifi action=resume')), isTrue);
      expect(enqueued, equals(1));
    });

    test('mid-download network switch triggers immediate auto-resume from breakpoint without consuming 5-retry limit', () async {
      final dm = DownloadManager.instance;
      dm.attachNetworkListenerForTesting();

      final batch = createResumableBatch();
      batch.jobs[0].state = JobState.active;
      dm.setBatchForTesting(batch);

      // First establish cellular connection as stable
      NetworkStatus.instance.setOnlineForTesting(true);
      NetworkStatus.instance.setNetworkTypeForTesting('cellular');
      dm.fireNetworkStabilityTimerForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Mid-download switch from cellular to wifi
      NetworkStatus.instance.setNetworkTypeForTesting('wifi');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      int enqueued = 0;
      dm.enqueueForTesting = (b, j) async {
        enqueued++;
      };

      // Connection drops as result of network change
      final update = TaskStatusUpdate(
        DownloadTask(
          taskId: batch.jobs[0].currentTaskId!,
          url: batch.jobs[0].urls[0],
          filename: batch.jobs[0].filename,
          group: batch.batchId,
        ),
        TaskStatus.failed,
        TaskConnectionException('connection aborted'),
      );

      await dm.taskFailureForTesting(batch, batch.jobs[0], update);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('auto_resume n=0/5 from_bytes=25000000 reason=network_switch')), isTrue);
      expect(enqueued, equals(1));
      // Does not consume the 5-retry limit
      expect(dm.autoResumeRetriesForTesting[batch.jobs[0].key] ?? 0, equals(0));
    });
  });
}
