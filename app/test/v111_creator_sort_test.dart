// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: the 创作者 view's sort menu.
//
// The ordering is a pure in-memory sort over the creator groups derived from
// the records the page already loaded: three keys, each in both directions,
// with a persisted choice. These tests drive the sort function and the
// settings round-trip directly; the widget test checks that the menu appears
// only in the 创作者 view.

import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/creator_sort.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestCreator implements CreatorSortable {
  TestCreator(
    this.sortName, {
    required this.sortPostCount,
    required this.sortLatestSavedMs,
    this.sortPlatform = 'xiaohongshu',
  });

  @override
  final String sortName;

  @override
  final int sortPostCount;

  @override
  final int sortLatestSavedMs;

  @override
  final String sortPlatform;
}

TestCreator g(String name, int posts, int savedMs,
        {String platform = 'xiaohongshu'}) =>
    TestCreator(name,
        sortPostCount: posts, sortLatestSavedMs: savedMs, sortPlatform: platform);

List<String> names(List<TestCreator> groups) =>
    [for (final g in groups) g.sortName];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('posts count', () {
    List<TestCreator> groups() => [
          g('alice', 3, 300),
          g('bob', 9, 100),
          g('carol', 1, 500),
        ];

    test('descending puts the most posts first', () {
      final list = sortCreators(groups(),
          mode: CreatorSort.postCount, descending: true);
      expect(names(list), ['bob', 'alice', 'carol']);
    });

    test('ascending puts the fewest posts first', () {
      final list = sortCreators(groups(),
          mode: CreatorSort.postCount, descending: false);
      expect(names(list), ['carol', 'alice', 'bob']);
    });
  });

  group('latest save', () {
    List<TestCreator> groups() => [
          g('alice', 3, 300),
          g('bob', 9, 100),
          g('carol', 1, 500),
        ];

    test('descending is the default and lists the newest first', () {
      expect(CreatorSortState.defaults.mode, CreatorSort.latestSaved);
      expect(CreatorSortState.defaults.descending, isTrue);
      final list = sortCreators(groups(),
          mode: CreatorSort.latestSaved, descending: true);
      expect(names(list), ['carol', 'alice', 'bob']);
    });

    test('ascending lists the oldest first', () {
      final list = sortCreators(groups(),
          mode: CreatorSort.latestSaved, descending: false);
      expect(names(list), ['bob', 'alice', 'carol']);
    });
  });

  group('name', () {
    List<TestCreator> groups() => [
          g('bob', 1, 100),
          g('Alice', 1, 200),
          g('carol', 1, 300),
        ];

    test('ascending is case-insensitive', () {
      final list =
          sortCreators(groups(), mode: CreatorSort.name, descending: false);
      expect(names(list), ['Alice', 'bob', 'carol']);
    });

    test('descending reverses the same comparison', () {
      final list =
          sortCreators(groups(), mode: CreatorSort.name, descending: true);
      expect(names(list), ['carol', 'bob', 'Alice']);
    });

    test('digits, Latin, CJK and emoji keep a documented, stable order', () {
      final mixed = [
        '猫猫',
        'alice',
        '3号',
        '10号',
        '🎉派对',
        '1号',
        'Zoe',
      ];
      final sorted = [...mixed]..sort(compareCreatorNames);
      // digits (numeric) -> Latin (case-insensitive) -> CJK (code point) ->
      // everything else (emoji/symbols).
      expect(sorted, ['1号', '3号', '10号', 'alice', 'Zoe', '猫猫', '🎉派对']);
      // Sorting the same input again never changes it.
      expect([...sorted]..sort(compareCreatorNames), sorted);
    });
  });

  group('unknown and empty authors', () {
    test('an empty name sorts last ascending and first descending', () {
      final groups = [
        g('', 5, 100),
        g('alice', 1, 200),
        g('小明', 2, 300),
      ];
      expect(
        names(sortCreators(groups, mode: CreatorSort.name, descending: false)),
        ['alice', '小明', ''],
      );
      expect(
        names(sortCreators(groups, mode: CreatorSort.name, descending: true)),
        ['', '小明', 'alice'],
      );
    });

    test('two unknown authors fall back to the newest save', () {
      final groups = [
        g('', 1, 100),
        g('', 1, 900),
      ];
      final sorted =
          sortCreators(groups, mode: CreatorSort.name, descending: false);
      expect([for (final g in sorted) g.sortLatestSavedMs], [900, 100]);
    });
  });

  group('tie-breaks', () {
    test('equal post counts fall back to the newest save', () {
      final groups = [
        g('alice', 2, 100),
        g('bob', 2, 900),
        g('carol', 2, 500),
      ];
      final sorted =
          sortCreators(groups, mode: CreatorSort.postCount, descending: true);
      expect(names(sorted), ['bob', 'carol', 'alice']);
    });

    test('identical names on two platforms stay in a fixed order', () {
      final groups = [
        g('alice', 1, 100, platform: 'xiaohongshu'),
        g('alice', 1, 100, platform: 'instagram'),
      ];
      final first =
          names(sortCreators(groups, mode: CreatorSort.name, descending: false));
      final second = names(sortCreators([...groups.reversed],
          mode: CreatorSort.name, descending: false));
      expect(first, second);
    });
  });

  group('settings round-trip', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to 最近保存 descending', () async {
      final settings = await AppSettings.load();
      expect(settings.creatorSort, CreatorSort.latestSaved);
      expect(settings.creatorSortDescending, isTrue);
    });

    test('the chosen key and direction survive a reload', () async {
      final settings = await AppSettings.load();
      settings.creatorSort = CreatorSort.name;
      settings.creatorSortDescending = false;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.creatorSort, CreatorSort.name);
      expect(reloaded.creatorSortDescending, isFalse);
    });

    test('an unknown stored value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'creatorSort': 'nonsense'});
      final settings = await AppSettings.load();
      expect(settings.creatorSort, CreatorSort.latestSaved);
    });
  });

  group('switching modes keeps each order computed from the same data', () {
    test('the list is re-sorted from the loaded groups, never mutated', () {
      final source = [
        g('alice', 3, 300),
        g('bob', 9, 100),
        g('carol', 1, 500),
      ];
      final byName = names(sortCreators([...source],
          mode: CreatorSort.name, descending: false));
      final byPosts = names(sortCreators([...source],
          mode: CreatorSort.postCount, descending: true));
      final byNameAgain = names(sortCreators([...source],
          mode: CreatorSort.name, descending: false));
      expect(byName, ['alice', 'bob', 'carol']);
      expect(byPosts, ['bob', 'alice', 'carol']);
      expect(byNameAgain, byName);
      // The source order is untouched by any of the sorts.
      expect(names(source), ['alice', 'bob', 'carol']);
    });
  });

  group('widget: creator sort menu', () {
    const photos = MethodChannel('com.fluttercandies/photo_manager');

    testWidgets('shown in 创作者 only, ordered by the default sort',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      DownloadManager.instance.clearBatchesForTesting();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(photos, null);
        HistoryDb.resetInstanceForTesting();
        GalleryLocatorService.instance.resetForTesting();
        DownloadManager.instance.clearBatchesForTesting();
      });

      await tester.runAsync(() async {
        final db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.clear();
        HistoryRecord record(String id, String author, int createdAt) =>
            HistoryRecord(
              platform: 'xhs',
              postId: id,
              postUrl: 'https://example.com/$id',
              authorName: author,
              title: '$author post',
              fileCount: 1,
              createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
              itemsJson: const JsonEncoder().convert([
                {'type': 'image', 'url': '', 'width': 100, 'height': 100}
              ]),
              files: [
                HistoryFile(
                  filename: '${id}_1.jpg',
                  savedAt: createdAt,
                  itemIndex: 1,
                  mediaId: 'media-$id',
                  status: FileStatus.found,
                ),
              ],
            );
        await db.upsert(record('post-a', 'alice', 1000));
        await db.upsert(record('post-b', 'bob', 900));
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      // 帖子 view: no creator menu.
      expect(find.byKey(const ValueKey('creator-sort-menu')), findsNothing);

      await tester.tap(find.text('创作者').first);
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('creator-sort-menu')), findsOneWidget);
      // 最近保存 descending: alice (1000) before bob (900).
      expect(
        [
          for (final card in tester.widgetList<CreatorCard>(
            find.byType(CreatorCard),
          ))
            card.authorName,
        ],
        ['alice', 'bob'],
      );
    });
  });
}
