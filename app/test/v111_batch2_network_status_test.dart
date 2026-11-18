// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 2: what the app says while a download has no network.
//
// Device report: in airplane mode a download stayed enqueued, the card kept
// spinning with no explanation, and switching the network back on resumed it.
// The resume is right; the silence is not. Nothing here changes the downloader
// (queuing, retry and resume stay untouched) — only what is displayed.

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/widgets/download_sheet.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _waiting = '等待网络…联网后自动继续';

DownloadBatch _batch(String id) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/abc',
  platform: 'xhs',
  postId: 'abc',
  title: 'Post',
  itemsJson: '[]',
  jobs: [
    DownloadJob(
      key: '$id-1',
      label: '图片 1',
      filename: 'abc_1.jpg',
      urls: ['https://sns-img.xhscdn.com/a.jpg'],
      isImage: true,
      itemIndex: 1,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = DownloadManager.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NetworkStatus.instance.resetForTesting();
    manager.clearBatchesForTesting();
  });

  tearDown(() {
    manager.clearBatchesForTesting();
    NetworkStatus.instance.resetForTesting();
  });

  test('starting offline says the download waits for the network', () {
    expect(downloadStartMessage(online: true), '已加入下载队列');
    expect(downloadStartMessage(online: false), '当前无网络，联网后自动开始');
  });

  test('the notification waits instead of pretending to transfer', () {
    expect(
      downloadNotificationTitle(done: 1, total: 3, waitingForNetwork: false),
      '正在下载 1/3',
    );
    expect(
      downloadNotificationBody(percent: 42, waitingForNetwork: false),
      '42%',
    );
    expect(
      downloadNotificationTitle(done: 1, total: 3, waitingForNetwork: true),
      '等待网络 1/3',
    );
    expect(
      downloadNotificationBody(percent: 42, waitingForNetwork: true),
      _waiting,
    );
  });

  testWidgets('the card overlay explains the wait and keeps cancel',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 240,
            child: DownloadingOverlay(
              progress: 0,
              waitingForNetwork: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text(_waiting), findsOneWidget);
    expect(find.text('下载中 0%'), findsNothing);
    // 4c: Cancel button removed from card overlay
    expect(find.byTooltip('取消下载'), findsNothing);
  });

  testWidgets('the download panel shows the wait, then resumes when the '
      'network comes back', (tester) async {
    final batch = _batch('net-1');
    manager.setBatchForTesting(batch);
    NetworkStatus.instance.setOnlineForTesting(false);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DownloadSheet(batchId: batch.batchId))),
    );
    // Header and the queued row both explain the wait; cancel stays available.
    expect(find.text(_waiting), findsWidgets);
    expect(find.text('取消'), findsOneWidget);

    NetworkStatus.instance.setOnlineForTesting(true);
    await tester.pump();

    expect(find.text(_waiting), findsNothing);
    expect(find.textContaining('正在保存'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // And back again: the panel follows the connection both ways.
    NetworkStatus.instance.setOnlineForTesting(false);
    await tester.pump();
    expect(find.text(_waiting), findsWidgets);
  });

  test('the batch itself is untouched by the reading', () {
    // Display only: no state, no progress and no job change comes from the
    // network reading.
    final batch = _batch('net-2');
    manager.setBatchForTesting(batch);
    NetworkStatus.instance.setOnlineForTesting(false);
    expect(batch.jobs.single.state, JobState.queued);
    expect(batch.isTerminal, isFalse);
    expect(batch.jobs.single.attempts, 0);
    NetworkStatus.instance.setOnlineForTesting(true);
    expect(batch.jobs.single.state, JobState.queued);
  });
}
