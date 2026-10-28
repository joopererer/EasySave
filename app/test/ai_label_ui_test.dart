import 'package:easysave/pages/download_queue_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/ai_label_badge.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final source in ['platform', 'author']) {
    testWidgets('AI badge shows verbatim text and $source attribution', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AiLabelBadge(text: '原文 AI  ', source: source))));
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      expect(find.text('原文 AI  '), findsOneWidget);
      expect(find.text(source == 'platform' ? '平台识别' : '作者声明'), findsOneWidget);
      expect(find.text('来自平台标注，仅供参考'), findsOneWidget);
    });
  }
  testWidgets('no label means no AI badge', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiLabelBadge(text: null)));
    expect(find.text('AI'), findsNothing);
  });
  testWidgets('saved waterfall card opens AI disclosure without opening post', (tester) async {
    var opened = false;
    final record = HistoryRecord(platform: 'xhs', postId: '123', postUrl: 'https://example.invalid',
        fileCount: 0, createdAt: DateTime(2026), aiLabel: '可能含AI生成内容', aiLabelSource: 'platform');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 220,
      child: WaterfallPostCard(record: record, onTap: () => opened = true)))));
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(find.text('可能含AI生成内容'), findsOneWidget);
  });
  testWidgets('local gallery preview exposes saved AI label', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GalleryBrowserPage(items: [], authorName: '',
      title: 'test', platform: 'tiktok', postUrl: '', aiLabel: 'Contains AI-generated media', aiLabelSource: 'platform')));
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('Contains AI-generated media'), findsOneWidget);
  });
  for (final isImage in [false, true]) {
    testWidgets('TikTok ${isImage ? 'image retains pause' : 'video offers only cancel'}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = DownloadManager.instance;
      final job = DownloadJob(key: 'ai-ui', label: 'file', filename: 'file', urls: ['https://example.invalid'],
          isImage: isImage, itemIndex: 1);
      final batch = DownloadBatch(batchId: 'ai-ui', album: 'EasySave', postUrl: 'https://example.invalid',
          platform: 'tiktok', postId: '123', jobs: [job], updatedAt: DateTime.now().millisecondsSinceEpoch);
      manager.setBatchForTesting(batch);
      await tester.pumpWidget(const MaterialApp(home: DownloadQueuePage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('暂停下载'), isImage ? findsOneWidget : findsNothing);
      expect(find.byTooltip(isImage ? '删除任务' : '取消'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.clearBatchesForTesting();
    });
  }
}
