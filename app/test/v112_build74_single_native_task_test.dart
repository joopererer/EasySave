import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/storage_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

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
    NetworkStatus.instance.setStatusForTesting(online: true, type: 'wifi');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, (call) async => true);

    tempDir = await Directory.systemTemp.createTemp('v112_b74_test_');
    PathProviderPlatform.instance = _FakePaths(tempDir.path);
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    DownloadManager.owner = DownloadBatch.sourceMain;
    DownloadManager.instance.activeQueryRetryDelay = Duration.zero;
    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.contentLengthProbeForTesting = (j, u) async => 100000000;
    DownloadManager.instance.mediaContentTypeForTesting = (p) async => const MediaContentType(MediaContentKind.video, 'mp4', 'video/mp4', playable: true);
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
    DownloadManager.roundWaitTimeout = const Duration(seconds: 10);
    DownloadManager.roundWaitPollInterval = const Duration(milliseconds: 100);
    DownloadManager.instance.activeQueryRetryDelay = const Duration(seconds: 30);
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.contentLengthProbeForTesting = null;
    DownloadManager.instance.mediaContentTypeForTesting = null;
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

  DownloadBatch createTestBatch({
    String batchId = 'single-native-b74-1',
    int partialBytes = 25000000,
    int totalBytes = 100000000,
  }) {
    final job = DownloadJob(
      key: '$batchId-0',
      label: 'video',
      filename: 'video.mp4',
      urls: ['https://video.twimg.com/video.mp4'],
      isImage: false,
      itemIndex: 0,
    )
      ..expectedBytes = totalBytes
      ..progress = partialBytes / totalBytes
      ..resumeStartByte = partialBytes
      ..state = JobState.active
      ..currentTaskId = '$batchId-0-r1'
      ..round = 1;

    final tempFile = File('${tempDir.path}/$batchId-0.tmp');
    tempFile.writeAsBytesSync(List.filled(1024, 0));
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

  group('v1.12 build 74: Item A - Single Native Task & Stale Task Handling', () {
    test('A6.1: Network switch mid-download logs observe and does NOT interrupt running job', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      DownloadManager.instance.setBatchForTesting(batch);

      // Simulate network transition wifi -> cellular
      NetworkStatus.instance.setStatusForTesting(online: true, type: 'cellular');
      DownloadManager.instance.onNetworkChangedForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final lines = DevLog.recentLines(500);
      expect(
        lines.any((e) => e.contains('network_change from=wifi to=cellular action=observe')),
        isTrue,
      );
      // Job remains active and running, not paused or canceled
      expect(job.state, equals(JobState.active));
      expect(job.error, isNull);
    });

    test('A6.2: Old round running delays enqueue; if unconfirmed before timeout, logs round_blocked and enters paused', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      job.round = 1;
      job.currentTaskId = '${job.key}-r1';
      DownloadManager.instance.setBatchForTesting(batch);

      // Mock old task as still running in plugin database
      DownloadManager.instance.recordForIdForTesting = (id) async {
        final t = DownloadTask(taskId: id, url: job.urls.first, filename: job.filename);
        return TaskRecord(t, TaskStatus.running, 0.5, 5000);
      };

      final cancelledTasks = <String>[];
      DownloadManager.instance.cancelTaskForTesting = (id) async {
        cancelledTasks.add(id);
      };

      // Set short timeouts for unit testing
      DownloadManager.roundWaitTimeout = const Duration(milliseconds: 60);
      DownloadManager.roundWaitPollInterval = const Duration(milliseconds: 10);

      // Attempt enqueue
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job, source: 'test_retry');

      final lines = DevLog.recentLines(500);
      expect(lines.any((e) => e.contains('round_wait old=${job.key}-r1 state=running')), isTrue);
      expect(cancelledTasks.contains('${job.key}-r1'), isTrue);
      expect(lines.any((e) => e.contains('round_blocked old=${job.key}-r1')), isTrue);

      // Transitioned to paused with "已中断，点继续"
      expect(job.state, equals(JobState.paused));
      expect(job.userPaused, isFalse);
      expect(job.error, equals('已中断，点继续'));
    });

    test('A6.3: Stale task reporting running or progress triggers zombie_task and is cancelled again', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      job.round = 3;
      job.currentTaskId = '${job.key}-r3';
      job.previousTaskIds = ['${job.key}-r1', '${job.key}-r2'];
      DownloadManager.instance.setBatchForTesting(batch);

      final cancelledTasks = <String>[];
      DownloadManager.instance.cancelTaskForTesting = (id) async {
        cancelledTasks.add(id);
      };

      final oldTask = DownloadTask(
        taskId: '${job.key}-r1',
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      // 1. Old task reports running
      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(oldTask, TaskStatus.running),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      var lines = DevLog.recentLines(500);
      expect(lines.any((e) => e.contains('zombie_task taskId=${job.key}-r1')), isTrue);
      expect(cancelledTasks.contains('${job.key}-r1'), isTrue);

      // 2. Old task reports progress
      cancelledTasks.clear();
      DownloadManager.instance.taskUpdateForTesting(
        TaskProgressUpdate(oldTask, 0.45),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      lines = DevLog.recentLines(500);
      expect(lines.any((e) => e.contains('zombie_task taskId=${job.key}-r1')), isTrue);
      expect(cancelledTasks.contains('${job.key}-r1'), isTrue);
    });

    test('A6.4: Stale task complete adopts file if valid, cancels current round, and finishes', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      job.round = 4;
      job.currentTaskId = '${job.key}-r4';
      job.previousTaskIds = ['${job.key}-r2'];
      job.expectedBytes = 5000000;
      DownloadManager.instance.setBatchForTesting(batch);

      final cancelledTasks = <String>[];
      DownloadManager.instance.cancelTaskForTesting = (id) async {
        cancelledTasks.add(id);
      };

      final r2Task = DownloadTask(
        taskId: '${job.key}-r2',
        url: job.urls.first,
        filename: job.filename,
        directory: downloadTempDirectory(batch.batchId, job.key),
        baseDirectory: BaseDirectory.temporary,
        group: batch.batchId,
        metaData: jsonEncode({
          'itemIndex': 0,
          'isImage': false,
        }),
      );

      // Write exactly 5000000 bytes to the task file path
      final filePath = await r2Task.filePath();
      final r2File = File(filePath);
      r2File.parent.createSync(recursive: true);
      final bytes = List<int>.filled(5000000, 0);
      bytes[3] = 0x18;
      bytes[4] = 0x66; // 'f'
      bytes[5] = 0x74; // 't'
      bytes[6] = 0x79; // 'y'
      bytes[7] = 0x70; // 'p'
      r2File.writeAsBytesSync(bytes);

      try {
        DownloadManager.instance.taskUpdateForTesting(
          TaskStatusUpdate(r2Task, TaskStatus.complete),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        final lines = DevLog.recentLines(500);
        expect(lines.any((e) => e.contains('adopt_stale_complete taskId=${job.key}-r2')), isTrue);
        // Cancelled current round r4
        expect(cancelledTasks.contains('${job.key}-r4'), isTrue);
        expect(job.currentTaskId, equals('${job.key}-r2'));
      } finally {
        try {
          if (r2File.existsSync()) r2File.deleteSync();
        } catch (_) {}
      }
    });

    test('A6.4b: Stale task complete with size mismatch or corrupt content is discarded', () async {
      final batch = createTestBatch();
      final job = batch.jobs.first;
      job.round = 3;
      job.currentTaskId = '${job.key}-r3';
      job.previousTaskIds = ['${job.key}-r1'];
      job.expectedBytes = 5000000;
      DownloadManager.instance.setBatchForTesting(batch);

      final r1Task = DownloadTask(
        taskId: '${job.key}-r1',
        url: job.urls.first,
        filename: job.filename,
        directory: downloadTempDirectory(batch.batchId, job.key),
        baseDirectory: BaseDirectory.temporary,
        group: batch.batchId,
      );

      // Write only 100 bytes (size mismatch against expectedBytes 5000000)
      final filePath = await r1Task.filePath();
      final r1File = File(filePath);
      r1File.parent.createSync(recursive: true);
      r1File.writeAsBytesSync(List.filled(100, 0));

      DownloadManager.instance.taskUpdateForTesting(
        TaskStatusUpdate(r1Task, TaskStatus.complete),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final lines = DevLog.recentLines(500);
      expect(lines.any((e) => e.contains('stale_complete_discarded taskId=${job.key}-r1')), isTrue);
      expect(r1File.existsSync(), isFalse);
      expect(job.currentTaskId, equals('${job.key}-r3'));
    });

    test('A6.5: Orphaned finished files and directories are swept without printing paths', () async {
      // 1. Active batch directory and job
      final activeBatchDir = Directory('${tempDir.path}/easysave/batch_live');
      activeBatchDir.createSync(recursive: true);
      final activeSubdir = Directory('${activeBatchDir.path}/job_active');
      activeSubdir.createSync(recursive: true);
      final activeFile = File('${activeSubdir.path}/valid.mp4');
      activeFile.writeAsBytesSync(List.filled(500, 0));

      // 2. Orphaned subdir inside active batch dir
      final orphanSubdir = Directory('${activeBatchDir.path}/orphan_job');
      orphanSubdir.createSync(recursive: true);
      final orphanFile1 = File('${orphanSubdir.path}/stale.mp4');
      orphanFile1.writeAsBytesSync(List.filled(1000, 0));

      // 3. Completely orphaned batch dir
      final deadBatchDir = Directory('${tempDir.path}/easysave/batch_dead');
      deadBatchDir.createSync(recursive: true);
      final deadFile = File('${deadBatchDir.path}/dead.mp4');
      deadFile.writeAsBytesSync(List.filled(2000, 0));

      final liveBatch = DownloadBatch(
        batchId: 'batch_live',
        album: 'EasySave',
        postUrl: 'https://x.com/user/status/1',
        platform: 'x',
        postId: '1',
        source: DownloadBatch.sourceMain,
        jobs: [
          DownloadJob(
            key: 'job_active',
            label: 'video',
            filename: 'valid.mp4',
            urls: ['https://x.com/v.mp4'],
            isImage: false,
            itemIndex: 0,
          )..state = JobState.active,
        ],
      );
      DownloadManager.instance.setBatchForTesting(liveBatch);

      final result = await DownloadManager.instance.tempSweep();

      // Files cleaned up
      expect(result.files, greaterThanOrEqualTo(2));
      expect(result.bytes, greaterThanOrEqualTo(3000));
      expect(orphanFile1.existsSync(), isFalse);
      expect(deadFile.existsSync(), isFalse);
      expect(activeFile.existsSync(), isTrue);

      final lines = DevLog.recentLines(500);
      final sweepLogs = lines.where((e) => e.contains('temp_sweep files=')).toList();
      expect(sweepLogs.isNotEmpty, isTrue);
      // Ensure no raw paths logged in temp_sweep
      expect(sweepLogs.any((e) => e.contains(tempDir.path)), isFalse);
      expect(sweepLogs.any((e) => e.contains('batch_dead')), isFalse);
    });
  });

  group('v1.12 build 74: Item B - Storage Shortage Distinction and Clean Button', () {
    test('B2: Storage shortage, user pause, and network interruption texts are mutually distinct', () {
      final batch = createTestBatch();
      final job = batch.jobs.first;

      // 1. Storage shortage
      job.state = JobState.paused;
      job.userPaused = false;
      job.errorCode = storageFullCode;
      job.error = '空间不足 · 需 3.50GB，可用 1.20GB';
      expect(batch.statusText, equals('空间不足 · 需 3.50GB，可用 1.20GB'));
      expect(batch.isUserPaused, isFalse);

      // 2. User paused
      job.state = JobState.paused;
      job.userPaused = true;
      job.errorCode = null;
      job.error = null;
      expect(batch.statusText, equals('已暂停'));
      expect(batch.isUserPaused, isTrue);

      // 3. Network interruption waiting for network
      job.state = JobState.paused;
      job.userPaused = false;
      job.errorCode = null;
      job.error = '下载中断 · 等待网络';
      expect(batch.statusText, equals('下载中断 · 等待网络'));
      expect(batch.isUserPaused, isFalse);

      // 4. Exhausted auto retries
      job.state = JobState.paused;
      job.userPaused = false;
      job.errorCode = null;
      job.error = '已中断，点继续';
      expect(batch.statusText, equals('已中断，点继续'));
      expect(batch.isUserPaused, isFalse);
    });
  });

  group('v1.12 build 74: Item C - Fallback Switch Constant', () {
    test('C1: kDefaultManualResumeOnlyOnDisconnect is false by default', () {
      expect(kDefaultManualResumeOnlyOnDisconnect, isFalse);
      final settings = AppSettings();
      expect(settings.manualResumeOnlyOnDisconnect, isFalse);
    });
  });
}
