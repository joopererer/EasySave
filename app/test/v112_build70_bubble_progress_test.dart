import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';
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

    tempDir = await Directory.systemTemp.createTemp('v112_b70_progress_test_');
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
    String batchId = 'bubble-test-batch',
    String source = DownloadBatch.sourceBackground,
    double progress = 0.0,
  }) {
    final job = DownloadJob(
      key: '$batchId-0',
      label: 'video',
      filename: 'video.mp4',
      urls: ['https://video.twimg.com/vid1.mp4'],
      isImage: false,
      itemIndex: 0,
    )
      ..progress = progress
      ..state = JobState.active
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

  group('build 70: item 0d - _countActiveNativeTasks timeout', () {
    test('timeout returns > 0 (1) and logs active_count_timeout', () async {
      final dm = DownloadManager.instance;
      dm.allRecordsForTesting = (batchId) async {
        throw TimeoutException('Simulated 500ms timeout');
      };

      final batch = createTestBatch(source: DownloadBatch.sourceMain);
      batch.jobs[0].state = JobState.failed;

      // Settlement check
      await dm.afterTerminalForTesting(batch, recovered: false);

      final logs = DevLog.recentLines(100);
      expect(logs.any((l) => l.contains('active_count_timeout id=bubble-test-batch')), isTrue);
      expect(logs.any((l) => l.contains('batch_settle_blocked id=bubble-test-batch active_native=1')), isTrue);
    });
  });

  group('build 70: item 1a/1b/1c - Bubble batch progress in App without takeover', () {
    test('1a: owning engine throttles progress persistence to SharedPreferences', () async {
      final dm = DownloadManager.instance;
      final batch = createTestBatch(batchId: 'main-own-batch', source: DownloadBatch.sourceMain);
      dm.setBatchForTesting(batch);

      final prefs = await SharedPreferences.getInstance();

      // Progress increased by >= 1%: 0.02
      batch.jobs[0].progress = 0.02;
      dm.throttlePersistProgressForTesting(batch, 0.02);

      final stored = await waitFor(() {
        final raw = prefs.getString('easysave_batch_${batch.batchId}');
        if (raw == null) return null;
        final decoded = DownloadBatch.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
        if ((decoded.jobs[0].progress - 0.02).abs() < 0.001) {
          return decoded;
        }
        return null;
      }, description: 'progress >= 1% persisted to SharedPreferences');
      expect(stored.jobs[0].progress, closeTo(0.02, 0.001));
    });

    test('1b & 1c: main UI reads foreign bubble snapshot progress without takeover', () async {
      final dm = DownloadManager.instance;
      final prefs = await SharedPreferences.getInstance();

      // Bubble writes a batch snapshot with 55% progress
      final bubbleBatch = createTestBatch(
        batchId: 'bubble-foreign-batch-1',
        source: DownloadBatch.sourceBackground,
        progress: 0.55,
      );
      await prefs.setString('easysave_batch_${bubbleBatch.batchId}', jsonEncode(bubbleBatch.toJson()));
      await prefs.setStringList('easysave_batches', [bubbleBatch.batchId]);

      // Main UI reads live batches
      final list = await dm.liveBatches();
      expect(list.length, equals(1));
      final readBatch = list.first;

      // Progress correctly reflected
      expect(readBatch.progress, closeTo(0.55, 0.001));
      // Ownership remains bubble (no takeover!)
      expect(readBatch.source, equals(DownloadBatch.sourceBackground));

      // Not written to main app's _batches (no takeover!)
      final inMem = dm.batchById(bubbleBatch.batchId);
      expect(inMem, isNull);
    });
  });
}

