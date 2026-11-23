// Copyright 2026 EasySave. All rights reserved.
// v1.12.1 Item D: History page "New content indicator" tests.
// Verifies:
// 1. D4: At top vs away from top scenarios: when user is at top, new content directly inserts without indicator banner
// 2. D1 & D5: When user is away from top, new content shows indicator banner; multiple new contents accumulate
// 3. D2: Tapping indicator scrolls to top, dismisses indicator, and highlights new cards for 1.5s
// 4. D3: Manually scrolling back to top dismisses indicator and highlights new cards

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/host_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const photos = MethodChannel('com.fluttercandies/photo_manager');

  HistoryRecord createMockRecord(String id, int index) {
    return HistoryRecord(
      platform: 'xhs',
      postId: id,
      title: 'Post Title $id',
      authorName: 'Author $id',
      thumbnailUrl: null,
      postUrl: 'https://example.com/$id',
      fileCount: 1,
      createdAt: DateTime.now().subtract(Duration(minutes: index)),
      itemsJson: jsonEncode([
        {'type': 'image', 'url': '$id.jpg', 'width': 300, 'height': 400},
      ]),
      files: [
        HistoryFile(
          filename: '$id.jpg',
          savedAt: 1000 + index,
          itemIndex: 1,
          isImage: true,
          status: FileStatus.found,
        ),
      ],
    );
  }

  Finder mainScrollable() => find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );

  Future<void> settle(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration maxDuration = const Duration(seconds: 2),
  }) async {
    final count = (maxDuration.inMilliseconds / 20).ceil();
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (condition()) return;
    }
  }

  group('Item D: History page new content indicator and highlight', () {
    testWidgets('D4: user at top -> new content does not show indicator', (tester) async {
      SharedPreferences.setMockInitialValues({
        'historyView': 'posts',
        'historyLayout': 'waterfall',
      });
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });

      late HistoryDb testDb;
      await tester.runAsync(() async {
        testDb = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(testDb);
        await testDb.clear();
        for (var i = 0; i < 5; i++) {
          await testDb.upsert(createMockRecord('post_$i', i), restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await settle(tester);

      final bannerFinder = find.byKey(const ValueKey('history_new_content_banner'));
      expect(bannerFinder, findsOneWidget);
      AnimatedOpacity opacityWidget = tester.widget(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      // Add a new post while at top
      await tester.runAsync(() async {
        await testDb.upsert(createMockRecord('post_new_top', 0), restoreDeleted: true, userSave: true, source: 'test');
      });
      HostBridge.historyRevision.value++;
      await settle(tester);

      opacityWidget = tester.widget(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);
    });

    testWidgets('D1 & D5: user away from top -> indicator shows and accumulates multiple new posts', (tester) async {
      SharedPreferences.setMockInitialValues({
        'historyView': 'posts',
        'historyLayout': 'waterfall',
      });
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });

      late HistoryDb testDb;
      await tester.runAsync(() async {
        testDb = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(testDb);
        await testDb.clear();
        for (var i = 0; i < 30; i++) {
          await testDb.upsert(createMockRecord('post_$i', i), restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await settle(tester);

      final scrollableFinder = mainScrollable();
      final scrollState = tester.state<ScrollableState>(scrollableFinder);
      final viewport = scrollState.position.viewportDimension;

      // Scroll away from top (> 1 screen, e.g. 2.0 screens)
      scrollState.position.jumpTo(2.0 * viewport);
      await tester.pump(const Duration(milliseconds: 100));

      // 1st new post arrives
      await tester.runAsync(() async {
        await testDb.upsert(createMockRecord('post_new_1', 0), restoreDeleted: true, userSave: true, source: 'test');
      });
      HostBridge.historyRevision.value++;
      await settle(tester);

      final bannerFinder = find.byKey(const ValueKey('history_new_content_banner'));
      expect(bannerFinder, findsOneWidget);
      AnimatedOpacity opacityWidget = tester.widget(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);
      expect(find.text('有 1 条新内容 ↑'), findsOneWidget);

      // 2nd new post arrives -> accumulates (D5)
      await tester.runAsync(() async {
        await testDb.upsert(createMockRecord('post_new_2', 0), restoreDeleted: true, userSave: true, source: 'test');
      });
      HostBridge.historyRevision.value++;
      await settle(tester);

      opacityWidget = tester.widget(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);
      expect(find.text('有 2 条新内容 ↑'), findsOneWidget);
    });

    testWidgets('D2: clicking indicator scrolls to top, clears banner, and highlights card for 1.5s', (tester) async {
      SharedPreferences.setMockInitialValues({
        'historyView': 'posts',
        'historyLayout': 'waterfall',
      });
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });

      late HistoryDb testDb;
      await tester.runAsync(() async {
        testDb = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(testDb);
        await testDb.clear();
        for (var i = 0; i < 30; i++) {
          await testDb.upsert(createMockRecord('post_$i', i), restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await settle(tester);

      final scrollableFinder = mainScrollable();
      final scrollState = tester.state<ScrollableState>(scrollableFinder);
      final viewport = scrollState.position.viewportDimension;

      // Scroll away from top
      scrollState.position.jumpTo(2.0 * viewport);
      await tester.pump(const Duration(milliseconds: 100));

      // New post arrives
      await tester.runAsync(() async {
        await testDb.upsert(createMockRecord('post_highlight_test', 0), restoreDeleted: true, userSave: true, source: 'test');
      });
      HostBridge.historyRevision.value++;
      await settle(tester);

      final bannerFinder = find.byKey(const ValueKey('history_new_content_banner'));
      expect(find.text('有 1 条新内容 ↑'), findsOneWidget);

      // Tap banner (D2)
      await tester.tap(bannerFinder);
      await pumpUntil(tester, () => scrollState.position.pixels == 0.0);

      // Reached top
      expect(scrollState.position.pixels, 0.0);

      // Banner is dismissed
      await tester.pump(const Duration(milliseconds: 300));
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      // After 1.5s timer expires, highlight clears
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets('D3: manually scrolling back to top clears banner and highlights card', (tester) async {
      SharedPreferences.setMockInitialValues({
        'historyView': 'posts',
        'historyLayout': 'waterfall',
      });
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });

      late HistoryDb testDb;
      await tester.runAsync(() async {
        testDb = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(testDb);
        await testDb.clear();
        for (var i = 0; i < 30; i++) {
          await testDb.upsert(createMockRecord('post_$i', i), restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await settle(tester);

      final scrollableFinder = mainScrollable();
      final scrollState = tester.state<ScrollableState>(scrollableFinder);
      final viewport = scrollState.position.viewportDimension;

      scrollState.position.jumpTo(2.0 * viewport);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.runAsync(() async {
        await testDb.upsert(createMockRecord('post_manual_scroll', 0), restoreDeleted: true, userSave: true, source: 'test');
      });
      HostBridge.historyRevision.value++;
      await settle(tester);

      final bannerFinder = find.byKey(const ValueKey('history_new_content_banner'));
      expect(find.text('有 1 条新内容 ↑'), findsOneWidget);

      // Manually scroll to top (D3)
      scrollState.position.jumpTo(0.0);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));

      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.ancestor(of: bannerFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      // 1.5s later highlight expires cleanly
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 350));
    });
  });
}

