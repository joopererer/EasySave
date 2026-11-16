// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: where the history list stands after every kind of change.
//
// Build 55 device report:
//   * 创作者 came back to the top after a few switches;
//   * picking an author there and switching to 帖子 / 全部 landed at the end.
//
// The rules, for all three modes (帖子 / 全部 / 创作者):
//   * switching mode keeps each mode's own position;
//   * the position is restored only once the target list has a real height;
//   * a filter or sort change starts at the top;
//   * going back to the unfiltered list returns to the position it had;
//   * a data update (refresh, background add/delete) keeps the card the user is
//     looking at in place, and so does returning from the viewer;
//   * a layout switch (瀑布流 ↔ 列表) keeps the first visible post on screen;
//   * a position outside the list becomes the top, never the end.
//
// The pure rules are asserted directly; the rest goes through the real
// HistoryPage, because that is where build 55 went wrong.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_scroll_memory.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/thumbnail_diagnostics.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int _postCount = 40;
const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

HistoryRecord _record(int index, DateTime createdAt, {String author = 'author'}) =>
    HistoryRecord(
      platform: 'xhs',
      postId: 'post-$index',
      postUrl: 'https://example.test/$index',
      title: 'Post $index',
      authorName: '$author-$index',
      fileCount: 1,
      createdAt: createdAt,
      itemsJson: jsonEncode([
        {
          'type': 'image',
          'url': 'https://sns-img.xhscdn.com/$index.jpg',
          'width': 1200,
          'height': 1600,
        },
      ]),
      files: [
        HistoryFile(
          filename: 'f_$index.jpg',
          savedAt: createdAt.millisecondsSinceEpoch,
          itemIndex: 1,
          mediaId: 'media-$index',
          status: FileStatus.found,
          relativePath: 'Pictures/EasySave/',
        ),
      ],
    );

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<HistoryPageState> pumpHistory(
  WidgetTester tester, {
  int count = _postCount,
}) async {
  SharedPreferences.setMockInitialValues({});
  HistoryDb.resetInstanceForTesting();
  ThumbnailDiagnostics.instance.resetForTesting();
  VerifiedAssetImage.resetKnownPresentForTesting();

  final assets = <AssetEntity>[
    for (var i = 0; i < count; i++)
      AssetEntity(
        id: 'media-$i',
        typeInt: AssetType.image.index,
        width: 1200,
        height: 1600,
        title: '$i.jpg',
      ),
  ];
  final locator = GalleryLocatorService.instance;
  locator.resetForTesting();
  locator.permissionReaderForTesting = () async => PermissionState.authorized;
  locator.albumReaderForTesting = () async => assets;
  locator.presenceProbeForTesting = (_) async => true;
  locator.setScannedForTesting(
    scanned: true,
    permission: PermissionState.authorized,
    assets: assets,
  );
  VerifiedAssetImage.existenceForTesting = (_) async => true;
  VerifiedAssetImage.providerForTesting = (_, _, _) =>
      MemoryImage(base64Decode(_png));

  final now = DateTime.now();
  await tester.runAsync(() async {
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    for (var i = 0; i < count; i++) {
      await db.upsert(_record(i, now.subtract(Duration(seconds: i))));
    }
  });

  final key = GlobalKey<HistoryPageState>();
  await tester.pumpWidget(MaterialApp(home: HistoryPage(key: key)));
  await settle(tester);
  return key.currentState!;
}

HistoryScrollKey _key({
  String view = 'posts',
  String? author,
  String platform = 'all',
  String query = '',
  String sort = 'latest',
  String creatorSort = 'postCount',
  bool desc = true,
}) => HistoryScrollKey(
  view: view,
  author: author,
  platform: platform,
  query: query,
  sort: sort,
  creatorSort: creatorSort,
  creatorSortDescending: desc,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    ThumbnailDiagnostics.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    HostBridge.historyRevision.value = 0;
  });

  group('the position rules, on their own', () {
    test('a position belongs to mode + filter + sort', () {
      expect(_key(), _key(query: '  '), reason: 'a blank search is no search');
      expect(_key(query: 'Cat'), _key(query: ' cat '));
      expect(_key(), isNot(_key(view: 'all')));
      expect(_key(), isNot(_key(author: 'a')));
      expect(_key(), isNot(_key(platform: 'xhs')));
      expect(_key(), isNot(_key(sort: 'earliest')));
      expect(
        _key(view: 'creators'),
        isNot(_key(view: 'creators', creatorSort: 'name')),
      );
      expect(
        _key(view: 'creators'),
        isNot(_key(view: 'creators', desc: false)),
      );
      expect(_key().unfiltered, isTrue);
      expect(_key(author: 'a').unfiltered, isFalse);
      expect(_key(query: 'x').unfiltered, isFalse);
      expect(_key(platform: 'xhs').unfiltered, isFalse);
    });

    test('a filter change starts at the top, clearing it returns', () {
      expect(
        destinationForChange(_key(author: 'a'), remembered: 120),
        ScrollDestination.top,
      );
      expect(
        destinationForChange(_key(query: 'cat'), remembered: 120),
        ScrollDestination.top,
      );
      expect(
        destinationForChange(_key(), remembered: 480),
        ScrollDestination.remembered,
        reason: 'back to the unfiltered list: where it was left',
      );
      expect(
        destinationForChange(_key(), remembered: null),
        ScrollDestination.top,
        reason: 'nothing was ever remembered, so there is nothing to return to',
      );
    });

    test('a position outside the list becomes the top, never the end', () {
      expect(resolveOffset(320, 1000), 320);
      expect(resolveOffset(-40, 1000), 0);
      expect(resolveOffset(double.nan, 1000), 0);
      expect(
        resolveOffset(1400, 420),
        0,
        reason: 'the record that was there is gone: stand at the top',
      );
      expect(resolveOffset(420.4, 420), 420, reason: 'a rounding overshoot');
      expect(resolveOffset(120, 0), 0, reason: 'a list with no extent');
    });

    test('the anchor is the card under the top edge', () {
      final anchor = pickAnchor(const [
        ScrollAnchor(key: 'p3', top: -800),
        ScrollAnchor(key: 'p4', top: -120),
        ScrollAnchor(key: 'p5', top: 40),
        ScrollAnchor(key: 'p6', top: 300),
      ]);
      expect(anchor?.key, 'p4');
      expect(anchor?.top, -120);

      // Everything is below the edge (the list is at its top).
      expect(
        pickAnchor(const [
          ScrollAnchor(key: 'p1', top: 8),
          ScrollAnchor(key: 'p2', top: 200),
        ])?.key,
        'p1',
      );
      expect(pickAnchor(const []), isNull);
    });

    test('a data update keeps what is on screen, a layout switch the first '
        'fully visible card', () {
      const candidates = [
        // Straddles the top edge: half of it is above the screen.
        ScrollAnchor(key: 'p1', top: -292, height: 300),
        ScrollAnchor(key: 'p2', top: 8, height: 300),
        ScrollAnchor(key: 'p3', top: 320, height: 300),
      ];
      expect(
        pickAnchor(candidates)?.key,
        'p1',
        reason: 'a record added above must not move what the user sees',
      );
      expect(
        pickAnchor(candidates, preference: AnchorPreference.aligned)?.key,
        'p2',
        reason: 'a layout switch cannot keep a half-scrolled card in place',
      );
      expect(
        pickAnchor(const [
          ScrollAnchor(key: 'p1', top: -292),
        ], preference: AnchorPreference.aligned)?.key,
        'p1',
        reason: 'with no fully visible card the straddling one is used',
      );
    });

    test('the anchored offset keeps the card where it was', () {
      // The card started 120 px above the edge and now starts 900 px in: the
      // list has to move 1020 px further to put it back.
      expect(anchorRestoreOffset(reveal: 900, delta: -120), 1020);
      expect(anchorRestoreOffset(reveal: 0, delta: 0), 0);
    });

    test('the memory keeps one offset per key', () {
      final memory = HistoryScrollMemory();
      memory.remember(_key(), 300);
      memory.remember(_key(view: 'all'), 90);
      expect(memory.offsetFor(_key()), 300);
      expect(memory.offsetFor(_key(view: 'all')), 90);
      expect(memory.offsetFor(_key(author: 'a')), isNull);
      expect(memory.length, 2);
      memory.remember(_key(), -5);
      expect(memory.offsetFor(_key()), 300, reason: 'not a position');
      memory.clear();
      expect(memory.length, 0);
    });
  });

  group('the real page', () {
    testWidgets('each mode keeps its own position', (tester) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);
      final postsOffset = page.scrollOffsetForTesting;
      expect(postsOffset, 300);

      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      expect(
        page.scrollOffsetForTesting,
        0,
        reason: 'creators was never scrolled',
      );
      page.scrollToForTesting(120);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('view_switcher_posts')));
      await settle(tester);
      expect(
        page.scrollOffsetForTesting,
        postsOffset,
        reason: '帖子 comes back where it was left',
      );

      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      expect(
        page.scrollOffsetForTesting,
        120,
        reason: '创作者 comes back where it was left',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('创作者 → 帖子 with an author starts at the top', (tester) async {
      final page = await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      // The user scrolled the creator grid before picking one.
      page.scrollToForTesting(200);
      await settle(tester);
      await tester.tap(find.byType(CreatorCard).first);
      await settle(tester);
      expect(page.scrollKeyForTesting.author, isNotNull);
      expect(
        page.scrollOffsetForTesting,
        0,
        reason: 'a filter change starts at the top, not at the end',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('clearing the filter returns to the unfiltered position', (
      tester,
    ) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);

      // Pick an author in 创作者: that adds a filter, so 帖子 starts at the top.
      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      await tester.tap(find.byType(CreatorCard).first);
      await settle(tester);
      expect(page.scrollKeyForTesting.author, isNotNull);
      expect(
        page.scrollOffsetForTesting,
        0,
        reason: 'a filter change starts at the top',
      );

      // Clear the filter chip: back to where the unfiltered list was left.
      await tester.tap(find.byIcon(Icons.close).first);
      await settle(tester);
      expect(page.scrollKeyForTesting.unfiltered, isTrue);
      expect(
        page.scrollOffsetForTesting,
        300,
        reason: 'the unfiltered list returns to where it was left',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a sort change starts at the top', (tester) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最早保存').last);
      await settle(tester);

      expect(page.scrollOffsetForTesting, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a refresh keeps the position', (tester) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);

      await tester.runAsync(() => page.reload());
      await settle(tester);

      expect(
        page.scrollOffsetForTesting,
        300,
        reason: 'the same records, the same place',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a record added at the top keeps the same card in view', (
      tester,
    ) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);
      final anchorKey = page.firstVisibleKeyForTesting;
      expect(anchorKey, isNotNull);
      final before = page.itemPlacementForTesting(anchorKey!)!;

      // A background download writes a newer post: it is inserted above.
      await tester.runAsync(() async {
        final db = await HistoryDb.instance();
        await db.upsert(_record(999, DateTime.now(), author: 'newcomer'));
      });
      HostBridge.historyRevision.value++;
      unawaited(page.reload());
      await settle(tester, frames: 16);

      expect(
        page.recordCountForTesting,
        greaterThan(_postCount),
        reason: 'the new record reached the page',
      );
      final after = page.itemPlacementForTesting(anchorKey);
      expect(
        after,
        isNotNull,
        reason: 'the card the user was looking at is still on screen',
      );
      expect(
        after!.$1,
        closeTo(before.$1, 1.0),
        reason: 'that card did not move: the list moved instead',
      );
      expect(
        after.$1 + after.$2,
        greaterThan(0),
        reason: 'the card is still visible',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      // The reload leaves deadline timers behind: let them fire once the tree
      // is gone instead of failing the test for a pending timer.
      await tester.pump(const Duration(seconds: 30));
      ThumbnailDiagnostics.instance.resetForTesting();
    });

    testWidgets('a shrinking list lands at the top, never at the end', (
      tester,
    ) async {
      final page = await pumpHistory(tester);
      // The page's own album scan writes to the same rows: let it finish before
      // the records are cut down, or the two deadlock on the database lock.
      await settle(tester, frames: 220);

      page.scrollToForTesting(600);
      await settle(tester);

      await tester.runAsync(() async {
        final db = await HistoryDb.instance();
        await db.clear();
        for (var i = 0; i < 2; i++) {
          await db.upsert(_record(i, DateTime.now()));
        }
      });
      HostBridge.historyRevision.value++;
      unawaited(page.reload());
      await settle(tester, frames: 16);

      expect(
        page.recordCountForTesting,
        2,
        reason: 'the records are gone',
      );
      expect(
        page.scrollOffsetForTesting,
        0,
        reason: 'the old position is outside the list',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a layout switch keeps the first visible post on screen', (
      tester,
    ) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(400);
      await settle(tester);
      final anchorKey = page.firstAlignedKeyForTesting;
      expect(anchorKey, isNotNull);
      final before = page.itemPlacementForTesting(anchorKey!)!;
      expect(before.$1, greaterThanOrEqualTo(0));

      await tester.tap(find.byTooltip('切换列表'));
      await settle(tester, frames: 12);
      await tester.pumpAndSettle();

      final after = page.itemPlacementForTesting(anchorKey);
      expect(after, isNotNull, reason: 'the post is still on screen');
      expect(
        after!.$1,
        closeTo(before.$1, 1.0),
        reason: 'the first fully visible post stayed exactly where it was',
      );
      expect(after.$1 + after.$2, greaterThan(0));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the position is restored only once the list has height', (
      tester,
    ) async {
      final page = await pumpHistory(tester);

      page.scrollToForTesting(300);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      // Switch back and look at the very next frame: the restore must not have
      // been clamped away by a list that had not been laid out yet.
      await tester.tap(find.byKey(const ValueKey('view_switcher_posts')));
      await tester.pump();
      await settle(tester);

      expect(page.scrollOffsetForTesting, 300);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
