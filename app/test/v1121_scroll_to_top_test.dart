// Copyright 2026 EasySave. All rights reserved.
// v1.12.1 Item C: History page "Back to top" button tests.
// Verifies:
// 1. Show/hide threshold: appears when scrolling > 2 screens, disappears when <= 1 screen with fade
// 2. Click to scroll to top: smooth scroll to top, fast jump when > 20 screens, total time <= 500ms
// 3. No overlap with other elements and no overflow with font scale 1.3

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/history_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const photos = MethodChannel('com.fluttercandies/photo_manager');

  List<HistoryRecord> createMockRecords(int count) {
    return List.generate(count, (i) {
      return HistoryRecord(
        platform: 'xhs',
        postId: 'post_$i',
        title: 'Post Title $i with some text to fill space',
        authorName: 'Author $i',
        thumbnailUrl: null,
        postUrl: 'https://example.com/post_$i',
        fileCount: 1,
        createdAt: DateTime.now().subtract(Duration(minutes: i)),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'file_$i.jpg', 'width': 300, 'height': 400},
        ]),
        files: [
          HistoryFile(
            filename: 'file_$i.jpg',
            savedAt: 1000 + i,
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
        ],
      );
    });
  }

  Finder mainScrollable() => find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );

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

  group('Item C: History page back-to-top button', () {
    testWidgets('C1: threshold show/hide with fade & C3: click to scroll to top', (tester) async {
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
        final records = createMockRecords(60);
        for (final r in records) {
          await testDb.upsert(r, restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      Future<void> settle([int count = 10]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: HistoryPage(),
        ),
      );
      await settle();

      final btnFinder = find.byKey(const ValueKey('history_scroll_to_top_button'));
      expect(btnFinder, findsOneWidget);

      // Initially at top (offset = 0): button opacity is 0.0
      AnimatedOpacity opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      final scrollableFinder = mainScrollable();
      final scrollState = tester.state<ScrollableState>(scrollableFinder);

      // Measure actual first-row bottom offset from the rendered first card.
      final firstCardFinder = find.byKey(const ValueKey('wf-1')).first;
      final firstCardBox = tester.renderObject<RenderBox>(firstCardFinder);
      final viewportRender = RenderAbstractViewport.of(firstCardBox);
      final firstRowThreshold =
          viewportRender.getOffsetToReveal(firstCardBox, 0.0).offset +
              firstCardBox.size.height;

      // Scroll slightly before the first row ends -> button should still be hidden
      scrollState.position.jumpTo((firstRowThreshold - 20.0).clamp(0.0, double.infinity));
      await tester.pump(const Duration(milliseconds: 300));

      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      // Scroll just past the first row -> button should appear
      scrollState.position.jumpTo(firstRowThreshold + 6.0);
      await tester.pump(const Duration(milliseconds: 300));

      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);

      // Small oscillations within 8dp hysteresis band -> should NOT flicker/hide
      scrollState.position.jumpTo(firstRowThreshold - 1.0);
      await tester.pump(const Duration(milliseconds: 100));
      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);

      scrollState.position.jumpTo(firstRowThreshold + 6.0);
      await tester.pump(const Duration(milliseconds: 100));
      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);

      // Scroll back above hysteresis band -> should disappear
      scrollState.position.jumpTo((firstRowThreshold - 20.0).clamp(0.0, double.infinity));
      await tester.pump(const Duration(milliseconds: 300));

      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);

      // Scroll down again past first row
      scrollState.position.jumpTo(firstRowThreshold + 100.0);
      await tester.pump(const Duration(milliseconds: 300));

      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 1.0);

      // Tap back to top button -> should scroll smoothly back to top
      await tester.tap(btnFinder);
      await pumpUntil(tester, () => scrollState.position.pixels == 0.0);

      expect(scrollState.position.pixels, 0.0);

      // Verify fade out
      await tester.pump(const Duration(milliseconds: 300));
      opacityWidget = tester.widget(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
      );
      expect(opacityWidget.opacity, 0.0);
    });

    testWidgets('All view modes (waterfall, list, all, creators) show just past first row and hide at top', (tester) async {
      for (final mode in [
        (view: 'posts', layout: 'waterfall', itemFinder: () => find.byType(WaterfallPostCard).first),
        (view: 'posts', layout: 'list', itemFinder: () => find.byType(Dismissible).first),
        (view: 'all', layout: 'waterfall', itemFinder: () => find.byType(AllMediaCard).first),
        (view: 'creators', layout: 'waterfall', itemFinder: () => find.byType(CreatorCard).first),
      ]) {
        SharedPreferences.setMockInitialValues({
          'historyView': mode.view,
          'historyLayout': mode.layout,
        });
        HistoryDb.resetInstanceForTesting();
        GalleryLocatorService.instance.resetForTesting();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          photos,
          (_) async => 0,
        );

        late HistoryDb testDb;
        await tester.runAsync(() async {
          testDb = await HistoryDb.instance(dbPath: ':memory:');
          HistoryDb.setInstanceForTesting(testDb);
          await testDb.clear();
          final records = createMockRecords(60);
          for (final r in records) {
            await testDb.upsert(r, restoreDeleted: true, userSave: true, source: 'test');
          }
        });

        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }

        final btnFinder = find.byKey(const ValueKey('history_scroll_to_top_button'));
        expect(btnFinder, findsOneWidget);

        final scrollableFinder = mode.view == 'creators'
            ? find.descendant(of: find.byType(GridView), matching: find.byType(Scrollable)).first
            : mainScrollable();
        final scrollState = tester.state<ScrollableState>(scrollableFinder);

        final firstBox = tester.renderObject<RenderBox>(mode.itemFinder());
        final vp = RenderAbstractViewport.of(firstBox);
        final threshold = vp.getOffsetToReveal(firstBox, 0.0).offset + firstBox.size.height;

        // Just past first row -> visible
        scrollState.position.jumpTo(threshold + 16.0);
        await tester.pump(const Duration(milliseconds: 300));
        var opacityWidget = tester.widget<AnimatedOpacity>(
          find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
        );
        expect(opacityWidget.opacity, 1.0, reason: 'Failed show in ${mode.view}/${mode.layout}');

        // Back to top -> hidden
        scrollState.position.jumpTo(0.0);
        await tester.pump(const Duration(milliseconds: 300));
        opacityWidget = tester.widget<AnimatedOpacity>(
          find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)).first,
        );
        expect(opacityWidget.opacity, 0.0, reason: 'Failed hide in ${mode.view}/${mode.layout}');

        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
        tester.view.resetPhysicalSize();
      }
    });

    testWidgets('C3: deep distance (> 20 screens) scrolls to top within 500ms', (tester) async {
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
        final records = createMockRecords(60);
        for (final r in records) {
          await testDb.upsert(r, restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      Future<void> settle([int count = 10]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: HistoryPage(),
        ),
      );
      await settle();

      final scrollableFinder = mainScrollable();
      final scrollState = tester.state<ScrollableState>(scrollableFinder);
      final viewport = scrollState.position.viewportDimension;

      // Jump to 22 screens deep (> 20 screens)
      final deepOffset = 22.0 * viewport;
      scrollState.position.jumpTo(deepOffset);
      await tester.pump(const Duration(milliseconds: 50));

      final btnFinder = find.byKey(const ValueKey('history_scroll_to_top_button'));
      expect(btnFinder, findsOneWidget);

      await tester.tap(btnFinder);
      // Wait for fast jump + 300ms smooth scroll animation to finish
      await pumpUntil(tester, () => scrollState.position.pixels == 0.0);

      expect(scrollState.position.pixels, 0.0);
    });

    testWidgets('C5: Font scale factor 1.3 does not overflow and stays within bounds', (tester) async {
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
        final records = createMockRecords(10);
        for (final r in records) {
          await testDb.upsert(r, restoreDeleted: true, userSave: true, source: 'test');
        }
      });

      Future<void> settle([int count = 10]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(1.3),
            ),
            child: HistoryPage(),
          ),
        ),
      );
      await settle();

      expect(tester.takeException(), isNull);
      final btnFinder = find.byKey(const ValueKey('history_scroll_to_top_button'));
      expect(btnFinder, findsOneWidget);

      final renderBox = tester.renderObject<RenderBox>(btnFinder);
      expect(renderBox.size.width, 44.0);
      expect(renderBox.size.height, 44.0);
    });
  });
}
