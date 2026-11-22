import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/delete_records_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helpers.dart';

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

    tempDir = await Directory.systemTemp.createTemp('v112_b72_test_');
    ResumableDownloadStore.instance.overrideDirectory = tempDir;

    DevLog.resetRecentForTesting();

    DownloadManager.owner = DownloadBatch.sourceMain;
    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.tempRootForTesting = () async => tempDir;
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.activeQueryRetryDelay = Duration.zero;

    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);

    DevLog.resetRecentForTesting();
    DownloadManager.owner = DownloadBatch.sourceMain;
    HistoryDb.setInstanceForTesting(null);
    HistoryDb.resetInstanceForTesting();
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
    DownloadManager.instance.recordForIdForTesting = null;
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.tempRootForTesting = null;
    DownloadManager.instance.activeQueryRetryDelay = const Duration(seconds: 30);
    DownloadManager.instance.clearBatchesForTesting();
    ResumableDownloadStore.instance.overrideDirectory = null;

    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createBatch({
    required String batchId,
    required String postId,
    required String platform,
    String source = DownloadBatch.sourceMain,
    required List<({String key, String filename, bool isImage, bool saved, String? mediaId, JobState state})> items,
  }) {
    final jobs = items.asMap().entries.map((entry) {
      final idx = entry.key;
      final it = entry.value;
      return DownloadJob(
        key: it.key,
        label: it.isImage ? 'image' : 'video',
        filename: it.filename,
        urls: ['https://example.com/${it.filename}'],
        isImage: it.isImage,
        itemIndex: idx + 1,
      )
        ..saved = it.saved
        ..mediaId = it.mediaId
        ..state = it.state
        ..currentTaskId = '${it.key}-task-r1';
    }).toList();

    return DownloadBatch(
      batchId: batchId,
      album: 'EasySave',
      postUrl: 'https://example.com/$platform/$postId',
      platform: platform,
      postId: postId,
      source: source,
      jobs: jobs,
    );
  }

  group('build 72: A1 - All items saved settles directly without plugin query', () {
    test('main engine: all saved items settle directly without calling plugin', () async {
      final batch = createBatch(
        batchId: 'main-saved-batch',
        postId: 'p_main_1',
        platform: 'x',
        source: DownloadBatch.sourceMain,
        items: [
          (key: 'job1', filename: 'vid.mp4', isImage: false, saved: true, mediaId: '79001', state: JobState.done),
          (key: 'job2', filename: 'img.jpg', isImage: true, saved: true, mediaId: '79002', state: JobState.done),
        ],
      );

      // If plugin is called, it should throw!
      DownloadManager.instance.recordForIdForTesting = (taskId) async {
        throw StateError('Plugin should not be queried when all items are saved');
      };
      DownloadManager.instance.allRecordsForTesting = (_) async {
        throw StateError('allRecords should not be queried when all items are saved');
      };

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      expect(batch.historyWritten, isTrue);
      expect(batch.settledBy, DownloadBatch.sourceMain);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('batch_settle') && l.contains('reason=all_completed') && l.contains('files=2')), isTrue);
      expect(logs.any((l) => l.contains('active_query')), isFalse);
      expect(logs.any((l) => l.contains('active_count_timeout')), isFalse);
    });

    test('bubble background engine: all saved items settle directly without calling plugin', () async {
      DownloadManager.owner = DownloadBatch.sourceBackground;

      final batch = createBatch(
        batchId: 'bubble-saved-batch',
        postId: 'p_bubble_1',
        platform: 'xhs',
        source: DownloadBatch.sourceBackground,
        items: [
          (key: 'img1', filename: '1.jpg', isImage: true, saved: true, mediaId: '79007', state: JobState.done),
          (key: 'img2', filename: '2.jpg', isImage: true, saved: true, mediaId: '79008', state: JobState.done),
          (key: 'img3', filename: '3.jpg', isImage: true, saved: true, mediaId: '79009', state: JobState.done),
          (key: 'img4', filename: '4.jpg', isImage: true, saved: true, mediaId: '79010', state: JobState.done),
        ],
      );

      DownloadManager.instance.recordForIdForTesting = (taskId) async {
        throw StateError('Plugin query forbidden when all items are saved');
      };

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      expect(batch.historyWritten, isTrue);
      expect(batch.settledBy, DownloadBatch.sourceBackground);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('batch_settle') && l.contains('by=background') && l.contains('reason=all_completed') && l.contains('files=4')), isTrue);
      expect(logs.any((l) => l.contains('active_query')), isFalse);
      expect(logs.any((l) => l.contains('active_count_timeout')), isFalse);
    });
  });

  group('build 72: A2/A3/A4 - Per-task query on unconfirmed and timeout fallback', () {
    test('queries only unconfirmed tasks with active_query log, blocks while active', () async {
      final batch = createBatch(
        batchId: 'unconfirmed-batch',
        postId: 'p_unconf',
        platform: 'x',
        items: [
          (key: 'job_ok', filename: '1.jpg', isImage: true, saved: true, mediaId: '79020', state: JobState.done),
          (key: 'job_fail', filename: '2.mp4', isImage: false, saved: false, mediaId: null, state: JobState.failed),
        ],
      );

      final queriedTaskIds = <String>[];
      DownloadManager.instance.recordForIdForTesting = (taskId) async {
        queriedTaskIds.add(taskId);
        final task = DownloadTask(taskId: taskId, url: 'https://example.com', group: batch.batchId);
        return TaskRecord(task, TaskStatus.running, 0.5, 1000);
      };

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      // Only the failed job's taskId was queried!
      expect(queriedTaskIds, ['job_fail-task-r1']);
      expect(batch.historyWritten, isFalse);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('active_query taskIds=1') && l.contains('result=1')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle_blocked id=unconfirmed-batch active_native=1')), isTrue);
    });

    test('3 consecutive timeouts fall back to App state with reason=native_query_unavailable and writes file rows', () async {
      final batch = createBatch(
        batchId: 'timeout-fallback-batch',
        postId: 'p_timeout_3',
        platform: 'x',
        items: [
          (key: 'job_ok', filename: 'ok.jpg', isImage: true, saved: true, mediaId: '79030', state: JobState.done),
          (key: 'job_fail', filename: 'fail.mp4', isImage: false, saved: false, mediaId: null, state: JobState.failed),
        ],
      );

      DownloadManager.instance.recordForIdForTesting = (taskId) async {
        throw TimeoutException('Simulated 3s timeout');
      };

      // Attempt 1: timeout
      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);
      expect(batch.historyWritten, isFalse);
      var logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('active_query taskIds=1') && l.contains('result=timeout')), isTrue);
      expect(logs.any((l) => l.contains('active_count_timeout id=timeout-fallback-batch')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle_blocked id=timeout-fallback-batch active_native=1')), isTrue);

      // Attempt 2: timeout
      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);
      expect(batch.historyWritten, isFalse);

      // Attempt 3: 3rd timeout triggers settlement with reason=native_query_unavailable!
      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);
      expect(batch.historyWritten, isTrue);
      expect(batch.settledBy, DownloadBatch.sourceMain);

      logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('batch_settle id=timeout-fallback-batch by=main reason=native_query_unavailable files=1 active_native=0')), isTrue);

      // Verify history has the file row
      final db = await HistoryDb.instance();
      final record = await waitFor(
        () async => await db.getByPostId('p_timeout_3'),
        description: 'wait for p_timeout_3 record in history',
      );
      expect(record, isNotNull);
      expect(record.files.length, 1);
      expect(record.files.first.mediaId, '79030');
    });

    test('bubble background engine also falls back on 3 timeouts with native_query_unavailable', () async {
      DownloadManager.owner = DownloadBatch.sourceBackground;

      final batch = createBatch(
        batchId: 'bubble-timeout-batch',
        postId: 'p_bubble_timeout',
        platform: 'xhs',
        source: DownloadBatch.sourceBackground,
        items: [
          (key: 'job_ok', filename: 'ok.jpg', isImage: true, saved: true, mediaId: '79040', state: JobState.done),
          (key: 'job_fail', filename: 'fail.jpg', isImage: true, saved: false, mediaId: null, state: JobState.failed),
        ],
      );

      DownloadManager.instance.recordForIdForTesting = (_) async => throw TimeoutException('timeout');

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);
      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);
      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      expect(batch.historyWritten, isTrue);
      expect(batch.settledBy, DownloadBatch.sourceBackground);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('batch_settle id=bubble-timeout-batch by=background reason=native_query_unavailable files=1 active_native=0')), isTrue);
    });
  });

  group('build 72: A5 - settle_repair on startup / reconcile', () {
    test('repairs stuck X post 2122697609731260512 (mediaId 79003) from build 70', () async {
      const postId = '2122697609731260512';
      const batchId = 'x-stuck-batch';

      // 1. Initial placeholder in SQLite with 0 files
      final db = await HistoryDb.instance();
      await db.upsert(
        HistoryRecord(
          platform: 'x',
          postId: postId,
          postUrl: 'https://x.com/user/status/$postId',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: const [],
        ),
        source: 'download-placeholder',
      );

      // 2. Persisted batch in SharedPreferences where file was imported to gallery (79003),
      // but batch was blocked before settlement.
      final batch = createBatch(
        batchId: batchId,
        postId: postId,
        platform: 'x',
        items: [
          (key: 'vid_job', filename: 'video.mp4', isImage: false, saved: true, mediaId: '79003', state: JobState.done),
        ],
      );
      batch.historyWritten = false;
      batch.settledBy = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('easysave_batches', [batchId]);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));

      // 3. App startup / reconcile
      await DownloadManager.instance.reconcile();

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('settle_repair batch=x-stuck-batch files=1')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle id=x-stuck-batch') && l.contains('reason=settle_repair') && l.contains('files=1')), isTrue);

      // 4. Verify History has file rows with mediaId 79003
      final updatedRecord = await waitFor(
        () async => await db.getByPostId(postId),
        description: 'wait for X post record after settle_repair',
      );
      expect(updatedRecord, isNotNull);
      expect(updatedRecord.fileCount, 1);
      expect(updatedRecord.files.length, 1);
      expect(updatedRecord.files.first.mediaId, '79003');
      expect(updatedRecord.downloadError, isNull);

      // 5. Verify visible in "最近保存" (recentSavedRecords)
      final allRecords = await db.recent();
      final savedPosts = recentSavedRecords(allRecords);
      expect(savedPosts.any((p) => p.postId == postId && p.fileCount == 1), isTrue);
    });

    test('repairs stuck XHS post 6aff266b000000001802b822 (mediaIds 79007-79010) from build 71', () async {
      const postId = '6aff266b000000001802b822';
      const batchId = 'xhs-bubble-stuck-batch';

      final db = await HistoryDb.instance();
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: postId,
          postUrl: 'https://xhs.com/explore/$postId',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: const [],
        ),
        source: 'download-placeholder',
      );

      final batch = createBatch(
        batchId: batchId,
        postId: postId,
        platform: 'xhs',
        source: DownloadBatch.sourceBackground, // created in bubble
        items: [
          (key: 'img1', filename: '1.jpg', isImage: true, saved: true, mediaId: '79007', state: JobState.done),
          (key: 'img2', filename: '2.jpg', isImage: true, saved: true, mediaId: '79008', state: JobState.done),
          (key: 'img3', filename: '3.jpg', isImage: true, saved: true, mediaId: '79009', state: JobState.done),
          (key: 'img4', filename: '4.jpg', isImage: true, saved: true, mediaId: '79010', state: JobState.done),
        ],
      );
      batch.historyWritten = false;
      batch.settledBy = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('easysave_batches', [batchId]);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));

      // Main app startup / reconcile
      await DownloadManager.instance.reconcile();

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('settle_repair batch=xhs-bubble-stuck-batch files=4')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle id=xhs-bubble-stuck-batch') && l.contains('reason=settle_repair') && l.contains('files=4')), isTrue);

      final updatedRecord = await waitFor(
        () async => await db.getByPostId(postId),
        description: 'wait for XHS post record after settle_repair',
      );
      expect(updatedRecord, isNotNull);
      expect(updatedRecord.fileCount, 4);
      expect(updatedRecord.files.length, 4);
      expect(updatedRecord.files.map((f) => f.mediaId).toList(), ['79007', '79008', '79009', '79010']);
      expect(updatedRecord.downloadError, isNull);

      final allRecords = await db.recent();
      final savedPosts = recentSavedRecords(allRecords);
      expect(savedPosts.any((p) => p.postId == postId && p.fileCount == 4), isTrue);
    });

    test('settle_repair works when bubble background engine starts first', () async {
      DownloadManager.owner = DownloadBatch.sourceBackground;

      const postId = 'bubble_repair_post';
      const batchId = 'bubble-repair-batch';

      final db = await HistoryDb.instance();
      await db.upsert(
        HistoryRecord(
          platform: 'x',
          postId: postId,
          postUrl: 'https://x.com/status/$postId',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: const [],
        ),
        source: 'download-placeholder',
      );

      final batch = createBatch(
        batchId: batchId,
        postId: postId,
        platform: 'x',
        source: DownloadBatch.sourceBackground,
        items: [
          (key: 'job1', filename: 'vid.mp4', isImage: false, saved: true, mediaId: '79050', state: JobState.done),
        ],
      );
      batch.historyWritten = false;
      batch.settledBy = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('easysave_batches', [batchId]);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));

      await DownloadManager.instance.reconcile();

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('settle_repair batch=bubble-repair-batch files=1')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle id=bubble-repair-batch by=background reason=settle_repair files=1')), isTrue);

      final updatedRecord = await waitFor(
        () async => await db.getByPostId(postId),
        description: 'wait for XHS post record after settle_repair',
      );
      expect(updatedRecord, isNotNull);
      expect(updatedRecord.fileCount, 1);
      expect(updatedRecord.files.first.mediaId, '79050');
    });
  });

  group('build 72: B1 - Delete confirmation dialog with 0 files', () {
    testWidgets('no files record shows only delete record copy, hides 0 项', (tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                host = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final future = showDeleteRecordsSheet(
        host,
        recordCount: 1,
        itemCount: 0,
        itemSummary: null,
        cancelDownloads: false,
      );
      await tester.pumpAndSettle();

      // Deletion prompt for records is shown
      expect(find.text('删除 1 条记录？'), findsOneWidget);
      expect(find.text('记录会从历史中移除，可以撤销。'), findsOneWidget);

      // "0 项" or "同时删除相册中的" MUST NEVER appear!
      expect(find.textContaining('0 项'), findsNothing);
      expect(find.textContaining('同时删除相册中的'), findsNothing);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await future, isNull);
    });

    testWidgets('even if itemSummary is "0 项", sheet hides album delete checkbox and 0 项 text', (tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                host = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final future = showDeleteRecordsSheet(
        host,
        recordCount: 1,
        itemCount: 0,
        itemSummary: '0 项',
        cancelDownloads: false,
      );
      await tester.pumpAndSettle();

      expect(find.text('删除 1 条记录？'), findsOneWidget);
      expect(find.textContaining('0 项'), findsNothing);
      expect(find.textContaining('同时删除相册中的'), findsNothing);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await future, isNull);
    });
  });
}
