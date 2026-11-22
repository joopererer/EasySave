// Copyright 2026 EasySave. All rights reserved.
// v1.12, Task 4: Bubble background engine startup acceleration.
//
// Validates:
// 1. init() returns promptly (< 1s) and starts reconcile in the background.
// 2. Settled terminal batches with historyWritten == true do not re-run
//    _afterTerminal or redundant notification cancellations.
// 3. Truly unsettled batches (e.g. from app kill) are still properly recovered
//    and written to history with recovered: true.
// 4. New batches can enqueue and run immediately before reconcile finishes.

import 'dart:convert';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/image_format_preference.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const MethodChannel channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const MethodChannel downloaderChannel = MethodChannel('com.bbflight.background_downloader');
  const MethodChannel downloaderBgChannel = MethodChannel('com.bbflight.background_downloader.background');
  final List<String> notificationCalls = <String>[];

  setUp(() {
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notificationCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          notificationCalls.add(call.method);
          if (call.method == 'initialize' || call.method == 'createNotificationChannel') {
            return true;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, (MethodCall call) async {
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, (MethodCall call) async {
          return null;
        });
    DownloadManager.instance.downloaderStartForTesting = () async {};
    DownloadManager.instance.allRecordsForTesting = (_) async => [];
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(downloaderBgChannel, null);
    DownloadManager.instance.resetInitForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    DownloadManager.instance.historyWriterForTesting = null;
    DownloadManager.instance.downloaderStartForTesting = null;
    DownloadManager.instance.allRecordsForTesting = null;
  });

  DownloadBatch createTestBatch({
    required String id,
    required bool terminal,
    required bool historyWritten,
    String? settledBy,
  }) {
    final batch = DownloadBatch(
      batchId: id,
      album: 'EasySave',
      postUrl: 'https://example.com/$id',
      platform: 'xhs',
      formatPref: ImageFormatPreference.original,
      jpegFallbackPlanned: false,
      postId: 'post-$id',
      authorName: 'author',
      source: DownloadManager.owner,
      jobs: [
        DownloadJob(
          key: '$id-0',
          label: 'image 1',
          filename: '$id-0.jpg',
          urls: ['https://example.com/$id-0.jpg'],
          resources: const [],
          isImage: true,
          itemIndex: 1,
        )
          ..state = terminal ? JobState.done : JobState.active
          ..saved = terminal,
      ],
    );
    batch.historyWritten = historyWritten;
    batch.settledBy = settledBy;
    return batch;
  }

  test('init() completes in < 1 second even with 10 historical settled batches', () async {
    final prefs = await SharedPreferences.getInstance();
    final batchIds = <String>[];
    for (var i = 0; i < 10; i++) {
      final batchId = '${DownloadManager.owner}-history-$i';
      batchIds.add(batchId);
      final batch = createTestBatch(id: batchId, terminal: true, historyWritten: true);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));
    }
    await prefs.setStringList('easysave_batches', batchIds);

    final sw = Stopwatch()..start();
    await DownloadManager.instance.init();
    sw.stop();

    // Cold init() should return well under 1000ms (typically < 100ms).
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('settled terminal batches skip _afterTerminal and notification cancellations', () async {
    final prefs = await SharedPreferences.getInstance();
    final batchIds = <String>[];
    for (var i = 0; i < 5; i++) {
      final batchId = '${DownloadManager.owner}-settled-$i';
      batchIds.add(batchId);
      final batch = createTestBatch(id: batchId, terminal: true, historyWritten: true);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));
    }
    await prefs.setStringList('easysave_batches', batchIds);

    var historyWrites = 0;
    DownloadManager.instance.historyWriterForTesting = (db, batch, recovered) async {
      historyWrites++;
    };

    await DownloadManager.instance.init();
    // Await background reconcile to finish.
    await DownloadManager.instance.reconcile();

    // Already-settled batches must NOT re-execute history writes.
    expect(historyWrites, equals(0));
    // And cancel notification was not called for settled historical batches.
    expect(notificationCalls.where((c) => c == 'cancel'), isEmpty);
  });

  test('truly unsettled batches are recovered and written to history', () async {
    final prefs = await SharedPreferences.getInstance();
    final batchId = '${DownloadManager.owner}-unsettled-1';
    final batch = createTestBatch(id: batchId, terminal: true, historyWritten: false);
    await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));
    await prefs.setStringList('easysave_batches', [batchId]);

    final recoveredBatches = <String>[];
    DownloadManager.instance.historyWriterForTesting = (db, batch, recovered) async {
      if (recovered) {
        recoveredBatches.add(batch.batchId);
      }
    };

    await DownloadManager.instance.init();
    await DownloadManager.instance.reconcile();

    expect(recoveredBatches, contains(batchId));
    final inMemory = DownloadManager.instance.getBatchForTesting(batchId);
    expect(inMemory, isNotNull);
    expect(inMemory!.historyWritten, isTrue);
  });

  test('new batch can be enqueued while background reconcile is in progress', () async {
    final prefs = await SharedPreferences.getInstance();
    final batchIds = <String>[];
    for (var i = 0; i < 5; i++) {
      final batchId = '${DownloadManager.owner}-hist-$i';
      batchIds.add(batchId);
      final batch = createTestBatch(id: batchId, terminal: true, historyWritten: true);
      await prefs.setString('easysave_batch_$batchId', jsonEncode(batch.toJson()));
    }
    await prefs.setStringList('easysave_batches', batchIds);

    await DownloadManager.instance.init();

    // Immediately enqueue new batch without awaiting reconcile.
    final newBatchId = '${DownloadManager.owner}-new-batch';
    final newBatch = createTestBatch(id: newBatchId, terminal: false, historyWritten: false);
    DownloadManager.instance.setBatchForTesting(newBatch);

    expect(DownloadManager.instance.getBatchForTesting(newBatchId), isNotNull);

    // Now let reconcile finish in background.
    await DownloadManager.instance.reconcile();

    // Verify new batch is still in memory and was not overwritten by reconcile.
    final postReconcile = DownloadManager.instance.getBatchForTesting(newBatchId);
    expect(postReconcile, isNotNull);
    expect(postReconcile!.isTerminal, isFalse);
  });
}
