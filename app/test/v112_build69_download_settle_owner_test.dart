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

    tempDir = await Directory.systemTemp.createTemp('v112_b69_test_');
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
    ResumableDownloadStore.instance.overrideDirectory = null;

    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createTestBatch({
    String batchId = 'main-test-batch',
    String source = DownloadBatch.sourceMain,
    int attempts = 1,
    JobState state = JobState.active,
  }) {
    final job = DownloadJob(
      key: '$batchId-0',
      label: 'video',
      filename: 'video.mp4',
      urls: ['https://video.twimg.com/vid1.mp4'],
      isImage: false,
      itemIndex: 0,
    )
      ..state = state
      ..attempts = attempts
      ..currentTaskId = '$batchId-0-task';

    return DownloadBatch(
      batchId: batchId,
      album: 'EasySave',
      postUrl: 'https://x.com/user/status/123',
      platform: 'x',
      postId: '123',
      source: source,
      jobs: [job],
    );
  }

  group('build 69: batch settlement & active native guard', () {
    test('settlement is blocked while native tasks are still active', () async {
      final batch = createTestBatch();
      batch.jobs[0].state = JobState.failed; // batch looks terminal in Dart

      // Native side still has an enqueued or running task!
      final task = DownloadTask(
        taskId: batch.jobs[0].currentTaskId!,
        url: batch.jobs[0].urls.first,
        group: batch.batchId,
      );
      DownloadManager.instance.allRecordsForTesting = (groupId) async => [
        TaskRecord(task, TaskStatus.running, 0.5, 5000),
      ];

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      expect(batch.historyWritten, isFalse);
      expect(
        DevLog.recentLines(100).any((l) =>
            l.contains('batch_settle_blocked') &&
            l.contains('id=${batch.batchId}') &&
            l.contains('active_native=1')),
        isTrue,
      );
    });

    test('settlement logs batch_settle and sets settledBy when all native tasks are done', () async {
      final batch = createTestBatch();
      batch.jobs[0].state = JobState.done;
      batch.jobs[0].saved = true;

      // Native tasks completed
      DownloadManager.instance.allRecordsForTesting = (groupId) async => [];

      await DownloadManager.instance.afterTerminalForTesting(batch, recovered: false);

      expect(batch.historyWritten, isTrue);
      expect(batch.settledBy, DownloadManager.owner);
      expect(
        DevLog.recentLines(100).any((l) =>
            l.contains('batch_settle') &&
            l.contains('id=${batch.batchId}') &&
            l.contains('files=1') &&
            l.contains('active_native=0')),
        isTrue,
      );
    });

    test('_reconcileBatch does not fail running or enqueued native tasks', () async {
      final batch = createTestBatch(attempts: 12); // attempts exhausted
      final task = DownloadTask(
        taskId: batch.jobs[0].currentTaskId!,
        url: batch.jobs[0].urls.first,
        group: batch.batchId,
      );
      DownloadManager.instance.allRecordsForTesting = (groupId) async => [
        TaskRecord(task, TaskStatus.running, 0.3, 3000),
      ];

      final changed = await DownloadManager.instance.reconcileBatchForTesting(batch);

      // Must remain active, not failed!
      expect(changed, isTrue);
      expect(batch.jobs[0].state, JobState.active);
      expect(batch.isTerminal, isFalse);
    });
  });

  group('build 69: single ownership & foreign batch adoption', () {
    test('canAdoptForeignBatch rejects settled or terminal successful batches', () {
      final now = 10000000;
      final staleTime = now - 10 * kStalledBatchAgeMs;

      // Unsettled stale batch with all tasks terminal can be adopted
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleTime,
          now: now,
          allTasksTerminal: true,
        ),
        isTrue,
      );

      // But if settledBy is set, CANNOT be adopted!
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleTime,
          now: now,
          allTasksTerminal: true,
          settledBy: DownloadBatch.sourceBackground,
        ),
        isFalse,
      );

      // If historyWritten is true, CANNOT be adopted!
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleTime,
          now: now,
          allTasksTerminal: true,
          historyWritten: true,
        ),
        isFalse,
      );

      // If isTerminal and succeeded > 0, CANNOT be adopted!
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleTime,
          now: now,
          allTasksTerminal: true,
          isTerminal: true,
          succeeded: 1,
        ),
        isFalse,
      );
    });

    test('forceAdopt changes owner in SharedPreferences and logs owner_change', () async {
      final batch = createTestBatch(source: DownloadBatch.sourceBackground);
      final adopted = await DownloadManager.instance.forceAdopt(batch);

      expect(adopted.source, DownloadManager.owner);
      expect(
        DevLog.recentLines(100).any((l) =>
            l.contains('owner_change') &&
            l.contains('batch=${batch.batchId}') &&
            l.contains('to=${DownloadManager.owner}') &&
            l.contains('reason=force_adopt')),
        isTrue,
      );
    });
  });

  group('build 69: saving sub-phases serialization', () {
    test('job.savingPhase serializes and deserializes cleanly', () {
      final job = DownloadJob(
        key: 'test-job',
        label: 'video',
        filename: 'v.mp4',
        urls: ['https://example.com/v.mp4'],
        isImage: false,
        itemIndex: 0,
      )
        ..isFinishing = true
        ..savingPhase = '写入来源信息';

      final json = job.toJson();
      expect(json['isFinishing'], isTrue);
      expect(json['savingPhase'], '写入来源信息');

      final restored = DownloadJob.fromJson(json);
      expect(restored.isFinishing, isTrue);
      expect(restored.savingPhase, '写入来源信息');
    });
  });
}
