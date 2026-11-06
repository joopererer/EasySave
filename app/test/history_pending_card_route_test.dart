import 'dart:convert';

import 'package:easysave/pages/download_queue_page.dart';
import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch _batch(JobState state) => DownloadBatch(
  batchId: 'pending-four', album: 'EasySave', platform: 'instagram',
  postId: 'pending-post', postUrl: 'https://www.instagram.com/p/pendingPost/',
  title: 'Selected pending post', postItemCount: 8,
  itemsJson: jsonEncode([
    for (var index = 1; index <= 8; index++)
      {'type': 'image', 'url': 'https://scontent.cdninstagram.com/$index.jpg'},
  ]),
  jobs: [
    for (final index in [2, 4, 6, 8])
      DownloadJob(key: 'pending-$index', label: '图片 $index', filename: 'pending-$index.jpg',
        urls: ['https://scontent.cdninstagram.com/$index.jpg'], isImage: true, itemIndex: index)
        ..state = state,
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> openHistory(WidgetTester tester, DownloadBatch batch, {
    bool list = false, bool earlierSaved = false,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'historyLayout': list ? 'list' : 'waterfall'});
    final manager = DownloadManager.instance;
    manager.clearBatchesForTesting();
    GalleryLocatorService.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => 0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(channel, null);
      manager.clearBatchesForTesting();
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      if (earlierSaved) {
        await db.upsert(HistoryRecord(
          platform: batch.platform, postId: batch.postId, postUrl: batch.postUrl,
          title: batch.title, itemsJson: batch.itemsJson,
          fileCount: 1, createdAt: DateTime(2026),
          files: [HistoryFile(filename: 'earlier-3.jpg', savedAt: 1,
            itemIndex: 3, status: FileStatus.found, mediaId: 'earlier-saved-3')],
        ));
      }
      await writePlaceholderHistory(db, batch);
    });
    manager.setBatchForTesting(batch);
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Selected pending post'), findsOneWidget);
  }

  for (final list in [false, true]) {
    for (final state in [JobState.active, JobState.failed]) {
      testWidgets('${list ? 'list' : 'waterfall'} history pending $state card opens its four jobs', (tester) async {
        await openHistory(tester, _batch(state), list: list);
        expect(find.byType(DownloadingOverlay), findsOneWidget);
        final overlay = find.byType(DownloadingOverlay);
        if (state == JobState.active) {
          final widget = tester.widget<DownloadingOverlay>(overlay);
          expect(widget.progress, 0);
        } else {
          final labels = tester.widgetList<Semantics>(find.descendant(
            of: overlay, matching: find.byType(Semantics)))
            .map((widget) => widget.properties.label ?? '');
          expect(labels.any((label) => label.contains('失败')), isTrue,
            reason: 'A terminal failed task must not still be called downloading.');
        }
        final pendingTitle = find.descendant(of: find.byType(HistoryPage),
            matching: find.text('Selected pending post'));
        await tester.ensureVisible(pendingTitle);
        await tester.tap(pendingTitle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(DownloadQueuePage), findsOneWidget,
          reason: 'A zero-saved pending card opens the selected job list, never a one-cover/full-post gallery.');
        expect(find.byType(GalleryBrowserPage), findsNothing);
        // The queue may focus/expand this batch on navigation or leave its card
        // collapsed; expand through the rendered control when needed.
        if (find.text('第 2 项').evaluate().isEmpty) {
          await tester.tap(find.descendant(of: find.byType(DownloadQueuePage),
              matching: find.text('Selected pending post')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
        for (var index = 1; index <= 8; index++) {
          expect(find.text('第 $index 项'), index.isEven ? findsOneWidget : findsNothing);
        }
        expect(find.text('已保存'), findsNothing);
        if (state == JobState.failed) {
          expect(find.descendant(of: find.byType(DownloadQueuePage),
              matching: find.textContaining('下载失败')), findsOneWidget);
          expect(find.text('重试失败项'), findsOneWidget);
          expect(find.byTooltip('重试此文件'), findsNWidgets(4));
        }
      });
    }
  }

  testWidgets('earlier successfully saved item still opens its gallery during another selected download', (tester) async {
    await openHistory(tester, _batch(JobState.active), earlierSaved: true);
    final savedTitle = find.descendant(of: find.byType(HistoryPage),
        matching: find.text('Selected pending post'));
    await tester.ensureVisible(savedTitle);
    await tester.tap(savedTitle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DownloadQueuePage), findsNothing);
    final browser = tester.widget<GalleryBrowserPage>(find.byType(GalleryBrowserPage));
    expect(browser.items, hasLength(1));
    expect(browser.items.single.index, 2);
    expect(browser.items.single.url, 'https://scontent.cdninstagram.com/3.jpg');
    expect(browser.items.single.filename, 'earlier-3.jpg');
  });
}
