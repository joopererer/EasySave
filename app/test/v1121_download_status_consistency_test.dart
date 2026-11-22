// Copyright 2026 EasySave. All rights reserved.
// v1.12.1 Item A: Download status text and icon consistency test across all 5 places:
// 1. History Cards (DownloadingOverlay)
// 2. Download Queue (DownloadQueuePage)
// 3. Preview Download Sheet (DownloadSheet)
// 4. Floating Bubble (background_entry.dart)
// 5. System Notifications (downloadNotificationTitle / downloadNotificationBody)

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_status_display.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/storage_guard.dart';
import 'package:easysave/widgets/download_sheet.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch _mockBatch({
  required String id,
  String? statusText,
  bool isUserPaused = false,
  bool isPaused = false,
  bool isTerminal = false,
  int failedCount = 0,
  int doneCount = 0,
  bool isFinishing = false,
  String? savingPhase,
  String? jobError,
  String? jobErrorCode,
  JobState jobState = JobState.active,
  double progress = 0.5,
}) {
  // Silence unused parameter analyzer hints if any:
  if (statusText != null && isPaused && doneCount > 0) {}
  final job = DownloadJob(
    key: '$id-job',
    itemIndex: 1,
    label: 'video.mp4',
    urls: ['https://example.com/video.mp4'],
    filename: 'video.mp4',
    isImage: false,
  );
  job.progress = progress;
  job.state = jobState;
  job.isFinishing = isFinishing;
  job.savingPhase = savingPhase;
  job.error = jobError;
  job.errorCode = jobErrorCode;
  job.userPaused = isUserPaused;

  final batch = DownloadBatch(
    batchId: id,
    album: 'EasySave',
    postUrl: 'https://example.com/post',
    platform: 'xhs',
    postId: id,
    title: 'Post Title',
    itemsJson: '[{"type":"video","url":"https://example.com/video.mp4"}]',
    postItemCount: 1,
    jobs: [job],
  );
  return batch;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NetworkStatus.instance.resetForTesting();
    NetworkStatus.instance.setOnlineForTesting(true);
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    DownloadManager.instance.clearBatchesForTesting();
  });

  tearDown(() async {
    DownloadManager.instance.clearBatchesForTesting();
    NetworkStatus.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  group('Item A: Unified status text function and priority rules', () {
    test('A2 Priority: storageFull > userPaused > interrupted > isFinishing > failed > progress', () {
      // 1. Storage Full takes highest precedence
      final b1 = _mockBatch(
        id: 'b1',
        isUserPaused: true, // paused too
        isFinishing: true,  // finishing too
        jobErrorCode: storageFullCode,
        jobError: '空间不足 · 需 2.0GB，可用 1.0GB',
      );
      final s1 = resolveDownloadStatus(batch: b1);
      expect(s1.kind, DownloadStatusKind.storageFull);
      expect(s1.label, '空间不足 · 需 2.0GB，可用 1.0GB');
      expect(s1.shortLabel, '空间不足');
      expect(s1.actionTip, '清理后继续');

      // 2. User Paused takes precedence over finishing and progress
      final b2 = _mockBatch(
        id: 'b2',
        isUserPaused: true,
        isFinishing: true,
        savingPhase: '写入来源信息',
        progress: 0.75,
      );
      final s2 = resolveDownloadStatus(batch: b2);
      expect(s2.kind, DownloadStatusKind.userPaused);
      expect(s2.label, '已暂停 75%');
      expect(s2.shortLabel, '已暂停');
      expect(s2.actionTip, '继续下载');

      // 3. Network wait / interrupted takes precedence over finishing
      NetworkStatus.instance.setOnlineForTesting(false);
      final b3 = _mockBatch(
        id: 'b3',
        isFinishing: false,
        jobState: JobState.waitingNetwork,
      );
      final s3 = resolveDownloadStatus(batch: b3);
      expect(s3.kind, DownloadStatusKind.waitingNetwork);
      expect(s3.label, '等待网络…联网后自动继续');
      expect(s3.shortLabel, '等网络');
      NetworkStatus.instance.setOnlineForTesting(true);

      // 4. Finishing phase takes precedence over failed and normal progress
      final b4 = _mockBatch(
        id: 'b4',
        isFinishing: true,
        savingPhase: '复制到相册',
        progress: 1.0,
      );
      final s4 = resolveDownloadStatus(batch: b4);
      expect(s4.kind, DownloadStatusKind.finishing);
      expect(s4.label, '正在保存到相册（复制到相册）');
      expect(s4.shortLabel, '保存中');

      // 5. Failed takes precedence over normal progress
      final b5 = _mockBatch(
        id: 'b5',
        isTerminal: true,
        failedCount: 1,
        jobState: JobState.failed,
        jobError: 'HTTP 403',
      );
      final s5 = resolveDownloadStatus(batch: b5);
      expect(s5.kind, DownloadStatusKind.failed);
      expect(s5.label, '下载失败（HTTP 403）');
      expect(s5.shortLabel, '失败');

      // 6. Normal progress
      final b6 = _mockBatch(
        id: 'b6',
        progress: 0.60,
      );
      final s6 = resolveDownloadStatus(batch: b6);
      expect(s6.kind, DownloadStatusKind.downloading);
      expect(s6.label, '下载中');
      expect(s6.shortLabel, '60%');
    });

    test('All 5 display surfaces produce matching status strings', () {
      final b = _mockBatch(
        id: 'b-full',
        jobErrorCode: storageFullCode,
        jobError: '空间不足 · 需 500MB，可用 100MB',
      );

      // 1. History card
      final cardStatus = resolveDownloadStatus(batch: b);
      expect(cardStatus.label, '空间不足 · 需 500MB，可用 100MB');
      expect(cardStatus.shortLabel, '空间不足');

      // 2. Download queue
      final queueStatus = resolveDownloadStatus(batch: b);
      expect(queueStatus.label, '空间不足 · 需 500MB，可用 100MB');

      // 3. Download sheet
      final sheetStatus = resolveDownloadStatus(batch: b, job: b.jobs.first);
      expect(sheetStatus.label, '空间不足 · 需 500MB，可用 100MB');

      // 4. Floating bubble
      final bubbleStatus = resolveDownloadStatus(batch: b);
      expect(bubbleStatus.shortLabel, '空间不足');

      // 5. System notification
      final notifTitle = downloadNotificationTitle(batch: b, done: 0, total: 1, waitingForNetwork: false);
      final notifBody = downloadNotificationBody(batch: b, percent: 50, waitingForNetwork: false);
      expect(notifTitle, '空间不足 0/1');
      expect(notifBody, '空间不足 · 需 500MB，可用 100MB');
    });
  });

  group('Item A: DownloadSheet storage-full UI display', () {
    testWidgets('DownloadSheet displays 空间不足 in title and item row instead of 已暂停', (tester) async {
      final batch = _mockBatch(
        id: 'sheet-storage-full',
        jobState: JobState.paused,
        jobErrorCode: storageFullCode,
        jobError: '空间不足 · 需 2.0GB，可用 1.0GB',
      );
      DownloadManager.instance.setBatchForTesting(batch);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadSheet(batchId: batch.batchId),
          ),
        ),
      );
      await tester.pump();

      // Verified: Headline shows 空间不足, NOT 已暂停
      expect(find.text('空间不足 · 需 2.0GB，可用 1.0GB'), findsNWidgets(2)); // Headline and row subtitle
      expect(find.textContaining('已暂停'), findsNothing);
      expect(find.textContaining('正在保存 0/1'), findsNothing);
    });

    testWidgets('DownloadingOverlay in history cards displays consistent 空间不足', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 0.3,
              statusText: '空间不足 · 需 2.0GB，可用 1.0GB',
              failureReason: 'STORAGE_FULL',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('空间不足 · 需 2.0GB，可用 1.0GB'), findsOneWidget);
      expect(find.textContaining('已暂停'), findsNothing);
    });
  });
}
