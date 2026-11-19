import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
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
  late String previousOwner;

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

    tempDir = await Directory.systemTemp.createTemp('v112_b71_bubble_test_');
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    previousOwner = DownloadManager.owner;
    DownloadManager.owner = DownloadBatch.sourceBackground;

    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.allRecordsForTesting = (_) async => [];
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);

    DownloadManager.owner = previousOwner;
    DevLog.resetRecentForTesting();
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;
    ResumableDownloadStore.instance.overrideDirectory = null;

    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createTestBatch({
    String batchId = 'bubble-multi-test',
    int jobCount = 2,
  }) {
    final jobs = List.generate(
      jobCount,
      (i) => DownloadJob(
        key: '$batchId-$i',
        label: 'image $i',
        filename: 'img_$i.jpg',
        urls: ['https://example.com/img_$i.jpg', 'https://example.com/img_${i}_alt.jpg'],
        isImage: true,
        itemIndex: i + 1,
      ),
    );

    return DownloadBatch(
      batchId: batchId,
      album: 'EasySave',
      postUrl: 'https://example.com/post/789',
      platform: 'example',
      postId: '789',
      source: DownloadBatch.sourceBackground,
      jobs: jobs,
    );
  }

  group('build 71: Item A - Bubble round-based updates and finish skipping', () {
    test('A1 & A6.1: Multi-image download with retry (-r1-try1 -> -r2-try2) has NO false stale_update', () async {
      final dm = DownloadManager.instance;
      final batch = createTestBatch();
      dm.setBatchForTesting(batch);

      final job0 = batch.jobs[0];
      job0.round = 1;
      job0.attempts = 1;
      job0.currentTaskId = '${job0.key}-r1-try1';
      job0.state = JobState.active;

      // 1. Valid round 1 task updates: enqueued, running, progress
      final taskR1 = DownloadTask(
        taskId: '${job0.key}-r1-try1',
        url: job0.urls.first,
        filename: job0.filename,
        group: batch.batchId,
      );

      dm.taskUpdateForTesting(TaskStatusUpdate(taskR1, TaskStatus.enqueued));
      dm.taskUpdateForTesting(TaskStatusUpdate(taskR1, TaskStatus.running));
      dm.taskUpdateForTesting(TaskProgressUpdate(taskR1, 0.45));

      expect(job0.progress, closeTo(0.45, 0.001));

      // 2. Retry to round 2 (-r2-try2)
      job0.round = 2;
      job0.attempts = 2;
      job0.currentTaskId = '${job0.key}-r2-try2';

      final taskR2 = DownloadTask(
        taskId: '${job0.key}-r2-try2',
        url: job0.urls[1],
        filename: job0.filename,
        group: batch.batchId,
      );

      dm.taskUpdateForTesting(TaskStatusUpdate(taskR2, TaskStatus.running));
      dm.taskUpdateForTesting(TaskProgressUpdate(taskR2, 0.95));

      expect(job0.progress, closeTo(0.95, 0.001));

      // 3. Late arriving update from old round 1 (-r1-try1) must be logged as stale
      dm.taskUpdateForTesting(TaskProgressUpdate(taskR1, 0.50));

      final logs = DevLog.recentLines(100);

      // Verify no stale_update for r1 before retry, nor for r2
      expect(
        logs.any((l) => l.contains('stale_update taskId=${job0.key}-r2-try2')),
        isFalse,
        reason: 'Current round 2 must not be treated as stale',
      );

      // Verify late round 1 update WAS treated as stale
      expect(
        logs.any((l) => l.contains('stale_update taskId=${job0.key}-r1-try1')),
        isTrue,
        reason: 'Past round 1 update after advance to round 2 is properly identified as stale',
      );
    });

    test('A2 & A6.2: Already-saved item triggers watchdog -> finish_skipped reason=already_saved', () async {
      final dm = DownloadManager.instance;
      final batch = createTestBatch();
      dm.setBatchForTesting(batch);

      final job0 = batch.jobs[0];
      job0.round = 1;
      job0.attempts = 1;
      job0.currentTaskId = '${job0.key}-r1-try1';
      job0.saved = true;
      job0.state = JobState.done;
      job0.lastProgressAt = DateTime.now().millisecondsSinceEpoch - 60000; // 60s ago (> 30s)

      // Watchdog ticks
      await dm.heartbeatTickForTesting();

      final logs = DevLog.recentLines(100);
      expect(
        logs.any((l) => l.contains('finish_skipped') && l.contains('reason=already_saved')),
        isTrue,
      );
      expect(job0.saved, isTrue);
      expect(job0.state, equals(JobState.done));
    });

    test('A1 & A6.3: Bubble polling reloadBatchSnapshot does not clobber live currentTaskId in memory', () async {
      final dm = DownloadManager.instance;
      final batch = createTestBatch();
      dm.setBatchForTesting(batch);

      final job0 = batch.jobs[0];
      job0.round = 1;
      job0.attempts = 1;
      job0.currentTaskId = '${job0.key}-r1-try1';

      // Simulate SharedPreferences having a stale snapshot without currentTaskId
      final prefs = await SharedPreferences.getInstance();
      final staleBatch = createTestBatch();
      staleBatch.jobs[0].currentTaskId = null; // Stale!
      await prefs.setString('easysave_batch_${batch.batchId}', jsonEncode(staleBatch.toJson()));

      // Bubble polling calls reloadBatchSnapshot
      final reloaded = await dm.reloadBatchSnapshot(batch.batchId);
      expect(reloaded, isNotNull);

      // In-memory batch must NOT have been overwritten
      final inMem = dm.batchById(batch.batchId);
      expect(inMem, isNotNull);
      expect(inMem!.jobs[0].currentTaskId, equals('${job0.key}-r1-try1'));

      // Subsequent update succeeds without stale_update
      final taskR1 = DownloadTask(
        taskId: '${job0.key}-r1-try1',
        url: job0.urls.first,
        filename: job0.filename,
        group: batch.batchId,
      );
      dm.taskUpdateForTesting(TaskProgressUpdate(taskR1, 0.70));

      final logs = DevLog.recentLines(100);
      expect(
        logs.any((l) => l.contains('stale_update taskId=${job0.key}-r1-try1')),
        isFalse,
      );
      expect(job0.progress, closeTo(0.70, 0.001));
    });

    test('A3: When temp file missing but already saved in HistoryDb, treats as saved without error', () async {
      final dm = DownloadManager.instance;
      final batch = createTestBatch();
      dm.setBatchForTesting(batch);

      final job0 = batch.jobs[0];
      job0.round = 1;
      job0.attempts = 1;
      job0.currentTaskId = '${job0.key}-r1-try1';

      // Insert pre-existing record into HistoryDb
      final db = await HistoryDb.instance();
      await db.upsert(HistoryRecord(
        platform: batch.platform,
        postId: batch.postId,
        postUrl: batch.postUrl,
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: job0.filename,
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: job0.itemIndex,
            isImage: true,
            assetId: 'asset-already-saved-123',
          ),
        ],
      ));

      final task = DownloadTask(
        taskId: '${job0.key}-r1-try1',
        url: job0.urls.first,
        filename: job0.filename,
        group: batch.batchId,
      );

      // Trigger finishFile
      await dm.afterTerminalForTesting(batch); // settlement or finish
      dm.taskUpdateForTesting(TaskStatusUpdate(task, TaskStatus.complete));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final logs = DevLog.recentLines(100);
      expect(
        logs.any((l) => l.contains('finish_skipped') && l.contains('reason=already_saved')),
        isTrue,
      );
      expect(job0.saved, isTrue);
      expect(job0.state, equals(JobState.done));
      expect(job0.error, isNull);
    });
  });
}
