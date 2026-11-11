import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/storage_guard.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('a parsed post whose download failed stays in history with its '
      'reason and a retry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    final manager = DownloadManager.instance..clearBatchesForTesting();
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      photos,
      (_) async => 0,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
      manager.clearBatchesForTesting();
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });

    const postId = '2118566677374022101';
    final items = jsonEncode([
      {'type': 'video', 'url': 'https://video.twimg.com/a.mp4', 'width': 720, 'height': 1280},
    ]);
    final batch = DownloadBatch(
      batchId: 'failed-large',
      album: 'EasySave',
      postUrl: 'https://x.com/i/status/$postId',
      platform: 'x',
      postId: postId,
      title: 'Large video',
      itemsJson: items,
      jobs: [
        DownloadJob(
          key: 'failed-large-1',
          label: '视频 1',
          filename: 'big.mp4',
          urls: ['https://video.twimg.com/a.mp4'],
          isImage: false,
          itemIndex: 1,
        )
          ..state = JobState.failed
          ..errorCode = storageFullCode
          ..error = storageFullMessage(requiredBytesForDownload(1095216660)),
      ],
    );
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      // What the terminal handler writes for a batch that saved nothing.
      await writeBatchHistory(db, batch, recovered: false);
    });
    manager.setBatchForTesting(batch);

    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(find.byType(WaterfallPostCard), findsOneWidget);
    expect(find.text('Large video'), findsOneWidget);
    expect(find.text('下载失败（存储空间不足），点击重试'), findsOneWidget);
    final overlay = tester.widget<DownloadingOverlay>(find.byType(DownloadingOverlay));
    expect(overlay.failed, isTrue);
    expect(overlay.onTogglePause, isNotNull, reason: 'the failure offers a retry');
  });
}
