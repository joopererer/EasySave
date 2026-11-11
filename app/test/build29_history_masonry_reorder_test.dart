import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:easysave/widgets/history_masonry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _heights = {'a': 180.0, 'b': 120.0, 'c': 150.0, 'd': 90.0, 'e': 160.0};

Widget _host(List<String> ids, {String label = ''}) => MaterialApp(
  home: Scaffold(
    body: CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: HistoryMasonryGrid(
            itemKeys: ids,
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

RenderObject _gridRender(WidgetTester tester) =>
    tester.renderObject(find.byType(MasonryGridView));

/// Every card starts where its column currently ends, the shortest column
/// first, so both columns are packed without holes.
void _expectPacked(List<Offset> topLefts, List<double> heights) {
  final columns = <double, double>{};
  final top = topLefts.first.dy;
  for (var i = 0; i < topLefts.length; i++) {
    final shortest = columns.length < 2
        ? top
        : columns.values.reduce((a, b) => a < b ? a : b);
    expect(topLefts[i].dy, moreOrLessEquals(shortest, epsilon: 0.5),
        reason: 'card $i');
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

  testWidgets('order changes replace the cached masonry layout; '
      'progress-only rebuilds keep it', (tester) async {
    await tester.pumpWidget(_host(['a', 'b', 'c', 'd', 'e']));
    final original = _gridRender(tester);
    await tester.pumpWidget(_host(['a', 'b', 'c', 'd', 'e'], label: '*'));
    expect(_gridRender(tester), same(original));

    final moved = ['e', 'a', 'b', 'c', 'd'];
    await tester.pumpWidget(_host(moved));
    expect(_gridRender(tester), isNot(same(original)));
    _expectPacked(
      [for (final id in moved) tester.getTopLeft(find.byKey(ValueKey('card-$id')))],
      [for (final id in moved) _heights[id]!],
    );

    final reordered = _gridRender(tester);
    await tester.pumpWidget(_host(['e', 'a', 'c', 'd']));
    expect(_gridRender(tester), isNot(same(reordered)), reason: 'deletion');
    final deleted = _gridRender(tester);
    await tester.pumpWidget(_host(['b', 'e', 'a', 'c', 'd']));
    expect(_gridRender(tester), isNot(same(deleted)), reason: 'insertion');
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

    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await settle();
    expect(cards().map((card) => card.record.postId), ['a', 'b', 'c', 'd', 'e']);
    expect(find.byType(MasonryGridView), findsNWidgets(2));
    final before = tester.renderObject(find.byType(MasonryGridView).first);

    await tester.runAsync(() async {
      await db.upsert(_record('e', DateTime.now(), files: 2), userSave: true);
    });
    HostBridge.historyRevision.value++;
    await settle();

    final ordered = cards();
    expect(ordered.map((card) => card.record.postId), ['e', 'a', 'b', 'c', 'd']);
    expect(find.byType(MasonryGridView), findsOneWidget);
    expect(_gridRender(tester), isNot(same(before)));
    final topLefts = [
      for (final card in ordered) tester.getTopLeft(find.byWidget(card)),
    ];
    final heights = [
      for (final card in ordered) tester.getSize(find.byWidget(card)).height,
    ];
    _expectPacked(topLefts, heights);
    expect(topLefts[1].dy, topLefts[0].dy, reason: 'second post beside first');
    expect(topLefts[1].dx, greaterThan(topLefts[0].dx));
  });
}
