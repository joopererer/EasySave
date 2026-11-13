// Copyright 2026 EasySave. All rights reserved.
// Two-column waterfall packing: no holes, both columns filled, and a post
// re-saved to the top still lands beside the newest one.
//
// v1.11 batch 2 replaced the render-object/shrink-wrapped grids with
// [LazyMasonrySliver]: the placement is computed from the cards' known heights
// (their covers' aspect ratios) and the cards themselves are built lazily by
// two sliver lists. The user-visible properties these tests pin did not change.

import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/widgets/balanced_masonry_view.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _heights = {'a': 180.0, 'b': 120.0, 'c': 150.0, 'd': 90.0, 'e': 160.0};

Widget _host(List<String> ids, {String label = ''}) => MaterialApp(
  home: Scaffold(
    body: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: LazyMasonrySliver(
            itemKeys: ids,
            estimatedHeightOf: (index, width) => _heights[ids[index]]!,
            itemBuilder: (_, index) => SizedBox(
              key: ValueKey('card-${ids[index]}'),
              height: _heights[ids[index]],
              child: Text('${ids[index]}$label'),
            ),
          ),
        ),
      ],
    ),
  ),
);

List<Offset> _topLefts(WidgetTester tester, List<String> ids) => [
  for (final id in ids) tester.getTopLeft(find.byKey(ValueKey('card-$id'))),
];

/// Every card starts where its column currently ends, the shortest column
/// first, so both columns are packed without holes.
void _expectPacked(List<Offset> topLefts, List<double> heights) {
  final columns = <double, double>{};
  final top = topLefts.first.dy;
  for (var i = 0; i < topLefts.length; i++) {
    final shortest = columns.length < 2
        ? top
        : columns.values.reduce((a, b) => a < b ? a : b);
    expect(
      topLefts[i].dy,
      moreOrLessEquals(shortest, epsilon: 0.5),
      reason: 'card $i',
    );
    columns[topLefts[i].dx] = topLefts[i].dy + heights[i] + 12;
  }
  expect(columns.length, 2, reason: 'both columns hold cards');
}

HistoryRecord _record(String id, DateTime createdAt, {int files = 1}) =>
    HistoryRecord(
      platform: 'xhs',
      postId: id,
      postUrl: 'https://example.test/$id',
      title: 'Post $id',
      fileCount: files,
      createdAt: createdAt,
      itemsJson: jsonEncode([
        for (var i = 1; i <= files; i++)
          {
            'type': 'image',
            'url': 'https://img.example/$id-$i.jpg',
            'width': id == 'c' ? 300 : 400,
            'height': id == 'b' ? 300 : 400,
          },
      ]),
      files: [
        for (var i = 1; i <= files; i++)
          HistoryFile(
            filename: '${id}_$i.jpg',
            savedAt: createdAt.millisecondsSinceEpoch,
            itemIndex: i,
            mediaId: 'media-$id-$i',
          ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('a reorder, a deletion and an insertion all keep both columns '
      'packed', (tester) async {
    await tester.pumpWidget(_host(['a', 'b', 'c', 'd', 'e']));
    _expectPacked(_topLefts(tester, ['a', 'b', 'c', 'd', 'e']), [
      for (final id in ['a', 'b', 'c', 'd', 'e']) _heights[id]!,
    ]);

    // A progress-only rebuild must not move anything.
    final before = _topLefts(tester, ['a', 'b', 'c', 'd', 'e']);
    await tester.pumpWidget(_host(['a', 'b', 'c', 'd', 'e'], label: '*'));
    expect(_topLefts(tester, ['a', 'b', 'c', 'd', 'e']), before);

    const moved = ['e', 'a', 'b', 'c', 'd'];
    await tester.pumpWidget(_host(moved));
    _expectPacked(_topLefts(tester, moved), [
      for (final id in moved) _heights[id]!,
    ]);

    const deleted = ['e', 'a', 'c', 'd'];
    await tester.pumpWidget(_host(deleted));
    _expectPacked(_topLefts(tester, deleted), [
      for (final id in deleted) _heights[id]!,
    ]);

    const inserted = ['b', 'e', 'a', 'c', 'd'];
    await tester.pumpWidget(_host(inserted));
    _expectPacked(_topLefts(tester, inserted), [
      for (final id in inserted) _heights[id]!,
    ]);
  });

  testWidgets('history waterfall fills both columns after the last post is '
      're-saved to the top', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      photos,
      (_) async => 0,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        null,
      );
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });
    final now = DateTime.now();
    late HistoryDb db;
    await tester.runAsync(() async {
      db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      for (final (index, id) in ['a', 'b', 'c', 'd'].indexed) {
        await db.upsert(
          _record(id, now.subtract(Duration(minutes: 10 + index))),
        );
      }
      // The last post starts in an older date group.
      await db.upsert(_record('e', now.subtract(const Duration(days: 3))));
    });
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    List<WaterfallPostCard> cards() => tester
        .widgetList<WaterfallPostCard>(find.byType(WaterfallPostCard))
        .toList();

    /// Card rectangles by post id. The two columns are separate sliver lists,
    /// so tree order no longer equals reading order — the geometry is what
    /// matters.
    Map<String, Rect> rects() => {
      for (final card in cards())
        card.record.postId: tester.getRect(find.byWidget(card)),
    };

    void expectNoOverlap(Map<String, Rect> byId) {
      final ids = byId.keys.toList();
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          expect(
            byId[ids[i]]!.overlaps(byId[ids[j]]!),
            isFalse,
            reason: '${ids[i]} overlaps ${ids[j]}',
          );
        }
      }
    }

    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await settle();
    final initial = rects();
    expect(initial.keys.toSet(), {'a', 'b', 'c', 'd', 'e'});
    expectNoOverlap(initial);
    // v1.11 batch 2: the 帖子 waterfall is the lazy balanced sliver.
    expect(find.byType(LazyMasonrySliver), findsNWidgets(2));

    await tester.runAsync(() async {
      await db.upsert(_record('e', DateTime.now(), files: 2), userSave: true);
    });
    HostBridge.historyRevision.value++;
    await settle();

    final byId = rects();
    expect(byId.keys.toSet(), {'e', 'a', 'b', 'c', 'd'});
    expect(find.byType(LazyMasonrySliver), findsOneWidget);
    expectNoOverlap(byId);
    expect(byId.values.map((rect) => rect.left).toSet(), hasLength(2),
        reason: 'both columns hold cards');
    // The re-saved post opens the layout: it is in the first row, beside
    // another card instead of alone in a half-empty row.
    final top = byId.values.map((rect) => rect.top).reduce(
      (a, b) => a < b ? a : b,
    );
    final firstRow =
        byId.values.where((rect) => rect.top == top).toList();
    expect(firstRow, hasLength(2));
    expect(byId['e']!.top, top);
  });
}
