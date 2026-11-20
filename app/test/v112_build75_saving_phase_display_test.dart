import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/widgets/history_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v1.12 build 75 Item A1: saving phase display on cards and queue', () {
    testWidgets('DownloadingOverlay shows 写入来源信息 during provenance phase', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              isFinishing: true,
              savingPhase: '写入来源信息',
            ),
          ),
        ),
      );

      expect(find.text('正在保存到相册（写入来源信息）'), findsOneWidget);
    });

    testWidgets('DownloadingOverlay shows 复制到相册 during gallery copy phase', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              isFinishing: true,
              savingPhase: '复制到相册',
            ),
          ),
        ),
      );

      expect(find.text('正在保存到相册（复制到相册）'), findsOneWidget);
    });

    testWidgets('Priority: storageFull > paused > isFinishing > progress', (tester) async {
      // 1. Storage shortage takes precedence over finishing
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              isFinishing: true,
              savingPhase: '写入来源信息',
              statusText: '空间不足 · 需 2.0GB，可用 1.0GB',
            ),
          ),
        ),
      );
      expect(find.text('空间不足 · 需 2.0GB，可用 1.0GB'), findsOneWidget);
      expect(find.textContaining('正在保存到相册'), findsNothing);

      // 2. User paused takes precedence over finishing
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              paused: true,
              userPaused: true,
              isFinishing: true,
              savingPhase: '写入来源信息',
            ),
          ),
        ),
      );
      expect(find.text('已暂停 100%'), findsOneWidget);
      expect(find.textContaining('正在保存到相册'), findsNothing);

      // 3. Finishing takes precedence over stale statusText or normal progress 100%
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              isFinishing: true,
              savingPhase: '复制到相册',
              statusText: '自动重试 1/5',
            ),
          ),
        ),
      );
      expect(find.text('正在保存到相册（复制到相册）'), findsOneWidget);
      expect(find.textContaining('自动重试'), findsNothing);
      expect(find.text('下载中 100%'), findsNothing);
    });

    test('DownloadJob savingPhase serialization and batch status text reflection', () {
      final job = DownloadJob(
        key: 'j1',
        itemIndex: 1,
        label: 'video',
        urls: ['https://example.com/video.mp4'],
        filename: 'video.mp4',
        isImage: false,
      );

      job.isFinishing = true;
      job.savingPhase = '写入来源信息';

      final map = job.toJson();
      expect(map['isFinishing'], isTrue);
      expect(map['savingPhase'], '写入来源信息');

      final restored = DownloadJob.fromJson(map);
      expect(restored.isFinishing, isTrue);
      expect(restored.savingPhase, '写入来源信息');
    });

    testWidgets('DownloadingOverlay displays percentage inside progress ring', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 0.65,
            ),
          ),
        ),
      );

      // Percentage is rendered in the ring Stack
      expect(find.text('65%'), findsOneWidget); // in progress ring
      expect(find.text('下载中 65%'), findsOneWidget); // in label
      expect(find.textContaining('65%'), findsNWidgets(2));
    });
  });
}
