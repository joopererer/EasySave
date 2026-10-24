// Copyright 2026 EasySave. All rights reserved.
// Tests for video provenance backfill upgrade hint (v1.8.2).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Video backfill upgrade hint', () {
    test('videoBackfillHintDismissed persistence in AppSettings', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      expect(settings.videoBackfillHintDismissed, isFalse);

      settings.videoBackfillHintDismissed = true;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.videoBackfillHintDismissed, isTrue);
    });

    test('videoBackfillHintDismissed is excluded from BackupSettings whitelist', () {
      final settings = BackupSettings(
        albumName: 'EasySave',
        usedAlbumNames: ['EasySave'],
        namePattern: '{id}_{seq}',
        saveProvenanceInImages: true,
        bubbleEnabled: true,
        bubbleAutoHide: true,
        backgroundToast: true,
        autoClipboard: true,
        saveCaptionTxt: false,
        historyView: 'posts',
        historyLayout: 'waterfall',
        historySort: 'latest',
      );

      final map = settings.toMap();
      expect(map.containsKey('videoBackfillHintDismissed'), isFalse);

      // Deserialization ignores it
      map['videoBackfillHintDismissed'] = true;
      final restored = BackupSettings.fromMap(map);
      expect(restored.toMap().containsKey('videoBackfillHintDismissed'), isFalse);
    });

    testWidgets('shows banner when video without assetId exists and not dismissed', (tester) async {
      bool dismissedCalled = false;
      bool backfillCalled = false;

      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'video_post_1',
          postUrl: 'https://xhs.com/video1',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [
            HistoryFile(
              filename: 'video.mp4',
              savedAt: 1000,
              isImage: false,
              assetId: null, // No assetId
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoBackfillHintBanner(
              dismissed: false,
              records: records,
              onDismiss: () => dismissedCalled = true,
              onBackfill: () => backfillCalled = true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('为已保存的视频补写来源信息'), findsOneWidget);
      expect(find.text('不再提示'), findsOneWidget);
      expect(find.text('去补写'), findsOneWidget);

      await tester.tap(find.text('不再提示'));
      await tester.pump();
      expect(dismissedCalled, isTrue);

      await tester.tap(find.text('去补写'));
      await tester.pump();
      expect(backfillCalled, isTrue);
    });

    testWidgets('does not show banner when dismissed is true', (tester) async {
      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'video_post_1',
          postUrl: 'https://xhs.com/video1',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [
            HistoryFile(
              filename: 'video.mp4',
              savedAt: 1000,
              isImage: false,
              assetId: null,
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoBackfillHintBanner(
              dismissed: true,
              records: records,
              onDismiss: () {},
              onBackfill: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('为已保存的视频补写来源信息'), findsNothing);
    });

    testWidgets('does not show banner when all videos have assetId', (tester) async {
      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'video_post_2',
          postUrl: 'https://xhs.com/video2',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [
            HistoryFile(
              filename: 'video.mp4',
              savedAt: 1000,
              isImage: false,
              assetId: 'urn:uuid:1234-video',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoBackfillHintBanner(
              dismissed: false,
              records: records,
              onDismiss: () {},
              onBackfill: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('为已保存的视频补写来源信息'), findsNothing);
    });

    testWidgets('does not show banner when only images exist', (tester) async {
      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'img_post_1',
          postUrl: 'https://xhs.com/img1',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [
            HistoryFile(
              filename: 'img.jpg',
              savedAt: 1000,
              isImage: true,
              assetId: null,
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoBackfillHintBanner(
              dismissed: false,
              records: records,
              onDismiss: () {},
              onBackfill: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('为已保存的视频补写来源信息'), findsNothing);
    });

    testWidgets('shows banner when video has empty string assetId', (tester) async {
      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'video_post_empty_id',
          postUrl: 'https://xhs.com/video_empty',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [
            HistoryFile(
              filename: 'video.mp4',
              savedAt: 1000,
              isImage: false,
              assetId: '', // Empty assetId
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoBackfillHintBanner(
              dismissed: false,
              records: records,
              onDismiss: () {},
              onBackfill: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('为已保存的视频补写来源信息'), findsOneWidget);
    });
  });
}
