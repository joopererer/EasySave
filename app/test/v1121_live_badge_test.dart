// Copyright 2026 EasySave. All rights reserved.
// v1.12.1 Item B: Live photo badge alignment and healing test.
// Verifies:
// 1. Cards (WaterfallPostCard, AllMediaCard) display LIVE badge for records from backup restore or scan
// 2. Both card and viewer use unified pairSavedMedia logic
// 3. Opening viewer logs [LiveBadge] post=<postId> card=yes viewer=yes
// 4. LiveBadgeRepairService heals missing pairId / itemsJson, logs live_badge_repair posts=<n> pairs=<n>, and runs only once.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_badge_repair_service.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late HistoryDb testDb;

  setUp(() async {
    HistoryDb.resetInstanceForTesting();
    dbPath = inMemoryDatabasePath;
    testDb = await HistoryDb.instance(dbPath: dbPath);
    DevLog.resetRecentForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
  });

  group('Item B: Card Live badge alignment with viewer via pairSavedMedia', () {
    testWidgets('WaterfallPostCard displays LIVE badge for record with paired files even if itemsJson has type: image', (tester) async {
      // Simulated post restored from backup or scan:
      // itemsJson has type 'image', but savedFiles contains paired image and video
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_live_1',
        title: 'XHS Live Post',
        authorName: 'author1',
        thumbnailUrl: null,
        postUrl: 'https://www.xiaohongshu.com/explore/post_live_1',
        fileCount: 2,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'xhs_post_live_1_1.jpg'},
        ]),
        files: [
          HistoryFile(
            filename: 'xhs_post_live_1_1.jpg',
            savedAt: 1000,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: 'xhs_post_live_1_1.mp4',
            savedAt: 1050,
            itemIndex: 1,
            isImage: false,
            status: FileStatus.found,
          ),
        ],
      );

      // Verify pairSavedMedia identifies it as Live
      final entries = pairSavedMedia(record.savedFiles);
      expect(entries.length, 1);
      expect(entries.first.isLive, isTrue);

      // Verify coverItemFor resolves type as 'live'
      final cover = coverItemFor(record);
      expect(cover, isNotNull);
      expect(cover!.type, 'live');
      expect(mediaKindLabel(cover), 'Live 图');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 300,
                child: WaterfallPostCard(
                  record: record,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Card must show LIVE badge
      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('AllMediaCard displays LIVE badge for record with paired files', (tester) async {
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_live_2',
        title: 'XHS Live Post 2',
        authorName: 'author2',
        thumbnailUrl: null,
        postUrl: 'https://www.xiaohongshu.com/explore/post_live_2',
        fileCount: 2,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'xhs_post_live_2_1.jpg'},
        ]),
        files: [
          HistoryFile(
            filename: 'xhs_post_live_2_1.jpg',
            savedAt: 2000,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: 'xhs_post_live_2_1.mp4',
            savedAt: 2050,
            itemIndex: 1,
            isImage: false,
            status: FileStatus.found,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 100,
              child: AllMediaCard(
                record: record,
                itemIndex: 1,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // In list row mode, listTypeBadge returns 'LIVE'
      expect(find.text('LIVE'), findsOneWidget);
    });
  });

  group('Item B: Viewer opens with diagnostic log [LiveBadge]', () {
    test('savedBrowserItems emits [LiveBadge] post=<postId> card=<yes|no> viewer=<yes|no>', () async {
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_diag_1',
        title: 'Diagnostic Post',
        authorName: 'author',
        thumbnailUrl: null,
        postUrl: 'https://example.com/post_diag_1',
        fileCount: 2,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'post_diag_1_1.jpg',
            savedAt: 1000,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: 'post_diag_1_1.mp4',
            savedAt: 1050,
            itemIndex: 1,
            isImage: false,
            status: FileStatus.found,
          ),
        ],
      );

      final built = await savedBrowserItems(
        record: record,
        files: record.visibleFiles,
        post: record.toPost(),
      );

      expect(built.items.isNotEmpty, isTrue);
      expect(built.items.first.type, 'live');

      // Check log
      final logs = DevLog.recentLines(50);
      final badgeLog = logs.firstWhere(
        (l) => l.contains('[LiveBadge]'),
        orElse: () => '',
      );
      expect(badgeLog, contains('post=post_diag_1 card=yes viewer=yes'));
      expect(badgeLog.contains('http'), isFalse); // No URLs or paths logged
    });
  });

  group('Item B: LiveBadgeRepairService startup repair', () {
    test('heals records missing pairId / itemsJson and runs only once', () async {
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();

      // Seed 2 records into testDb:
      // Record 1: Paired Live photo with missing pairId and itemsJson has type 'image'
      final r1 = HistoryRecord(
        platform: 'xhs',
        postId: 'post_heal_1',
        title: 'Heal Post 1',
        authorName: 'author1',
        thumbnailUrl: null,
        postUrl: 'https://example.com/p1',
        fileCount: 2,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'xhs_p1_1.jpg'},
        ]),
        files: [
          HistoryFile(
            filename: 'xhs_p1_1.jpg',
            savedAt: 1000,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: 'xhs_p1_1.mp4',
            savedAt: 1050,
            itemIndex: 1,
            isImage: false,
            status: FileStatus.found,
          ),
        ],
      );

      // Record 2: Normal non-live image post
      final r2 = HistoryRecord(
        platform: 'xhs',
        postId: 'post_heal_2',
        title: 'Normal Post',
        authorName: 'author2',
        thumbnailUrl: null,
        postUrl: 'https://example.com/p2',
        fileCount: 1,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'xhs_p2_1.jpg'},
        ]),
        files: [
          HistoryFile(
            filename: 'xhs_p2_1.jpg',
            savedAt: 2000,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
        ],
      );

      await testDb.upsert(r1, restoreDeleted: true, userSave: true, source: 'test');
      await testDb.upsert(r2, restoreDeleted: true, userSave: true, source: 'test');

      // First run: should repair r1
      final res1 = await LiveBadgeRepairService.repairIfNeeded(
        db: testDb,
        prefs: sp,
      );
      expect(res1.posts, 1);
      expect(res1.pairs, 1);

      // Verify repair log
      final logs = DevLog.recentLines(50);
      final repairLog = logs.firstWhere(
        (l) => l.contains('live_badge_repair'),
        orElse: () => '',
      );
      expect(repairLog, contains('live_badge_repair posts=1 pairs=1'));

      // Verify r1 in database has been healed
      final updatedR1 = await testDb.getByPostId('post_heal_1', platform: 'xhs');
      expect(updatedR1, isNotNull);
      expect(updatedR1!.files.every((f) => f.pairId == 'post_heal_1#1'), isTrue);
      final post1 = updatedR1.toPost();
      expect(post1.items.first.type, 'live');

      // Second run: should be skipped (runs only once)
      final res2 = await LiveBadgeRepairService.repairIfNeeded(
        db: testDb,
        prefs: sp,
      );
      expect(res2.posts, 0);
      expect(res2.pairs, 0);
    });
  });
}
