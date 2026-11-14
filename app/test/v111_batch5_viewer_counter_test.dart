// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 5: the counter shrinks with the items the user deleted.
//
// The total is the post's total minus the items deleted in the app, the
// position is the item's own place minus the deleted ones before it, and items
// that are "not on this device" or were never downloaded keep their slot. A
// Live photo counts once, however many rows it leaves behind.

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postUrl = 'https://www.xiaohongshu.com/explore/2118566677374022101';

GalleryBrowserItem _item(
  int index, {
  bool missing = false,
  String type = 'image',
}) => GalleryBrowserItem(
  index: index,
  type: type,
  url: '',
  missing: missing,
  status: missing ? FileStatus.notFound : FileStatus.found,
);

HistoryFile _row(
  int index,
  FileStatus status, {
  bool image = true,
  String? mediaId,
}) => HistoryFile(
  filename: 'post_$index.${image ? 'jpg' : 'mp4'}',
  savedAt: 1,
  mediaId: mediaId,
  status: status,
  itemIndex: index,
  isImage: image,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<GalleryBrowserItem> items,
  required int total,
  int initialIndex = 0,
  Set<int> deletedIndices = const <int>{},
}) async {
  // A fresh state: a second pump of the same page would keep the old one.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      home: GalleryBrowserPage(
        items: items,
        initialIndex: initialIndex,
        originalTotal: total,
        deletedIndices: deletedIndices,
        authorName: 'a',
        title: 't',
        platform: 'xhs',
        postUrl: _postUrl,
        onDeleteItem: (item, {required bool deleteAlbumFiles}) async =>
            GalleryBrowserItemDeletion(
              ok: true,
              undo: () async {},
            ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _deleteCurrent(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('delete_item')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('仅删除记录'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VerifiedAssetImage.resetKnownPresentForTesting();
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    GalleryLocatorService.instance.resetForTesting();
    VerifiedAssetImage.existenceForTesting = null;
  });

  group('the numbering', () {
    test('no delete keeps the original place', () {
      final counter = browserCounterFor(
        itemIndex: 2,
        baseTotal: 8,
        deleted: <int>{},
      );
      expect(counter.label, '3 / 8');
    });

    test('a deleted item before this one moves it up and shrinks the total',
        () {
      final counter = browserCounterFor(
        itemIndex: 2,
        baseTotal: 8,
        deleted: <int>{0},
      );
      expect(counter.label, '2 / 7');
    });

    test('a deleted item after this one only shrinks the total', () {
      final counter = browserCounterFor(
        itemIndex: 1,
        baseTotal: 8,
        deleted: <int>{5},
      );
      expect(counter.label, '2 / 7');
    });

    test('items never downloaded keep their slot', () {
      final counter = browserCounterFor(
        itemIndex: 4,
        baseTotal: 8,
        deleted: <int>{},
      );
      expect(counter.label, '5 / 8');
    });

    test('the last item of a fully deleted post still reads 1 / 1', () {
      final counter = browserCounterFor(
        itemIndex: 0,
        baseTotal: 1,
        deleted: <int>{},
      );
      expect(counter.label, '1 / 1');
    });

    test('a Live pair leaves one deleted item, not two', () {
      final files = [
        _row(1, FileStatus.found, mediaId: '11'),
        _row(2, FileStatus.deleted, mediaId: '21'),
        _row(2, FileStatus.deleted, mediaId: '22', image: false),
      ];
      expect(deletedItemIndices(files), <int>{1});
      final counter = browserCounterFor(
        itemIndex: 2,
        baseTotal: 3,
        deleted: deletedItemIndices(files),
      );
      expect(counter.label, '2 / 2');
    });

    test('legacy zero-based rows are read as they were written', () {
      final files = [
        _row(0, FileStatus.deleted),
        _row(1, FileStatus.found, mediaId: '12'),
        _row(2, FileStatus.notFound),
      ];
      expect(deletedItemIndices(files), <int>{0});
    });

    test('rows without a delete are no deleted items', () {
      expect(
        deletedItemIndices([
          _row(1, FileStatus.found, mediaId: '11'),
          _row(2, FileStatus.notFound),
        ]),
        isEmpty,
      );
    });
  });

  group('the viewer', () {
    testWidgets('deleting the first item shrinks the total', (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
      );
      expect(find.text('1 / 3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('1 / 2'), findsOneWidget,
          reason: 'the next item moved up into 1 / 2');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting a middle item keeps the page in place on 2 / 2',
        (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2 / 3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('2 / 2'), findsOneWidget,
          reason: 'the third item is not renumbered past the end');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting the last item steps back to the new end',
        (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
        initialIndex: 2,
      );
      expect(find.text('3 / 3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('2 / 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('undo puts the count back', (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
      );

      await _deleteCurrent(tester);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget,
          reason: 'the deleted item is back and the total with it');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an item that is not on this device keeps its number',
        (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1, missing: true), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('不在本机'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('items that were never downloaded keep their slot',
        (tester) async {
      final stored = [_item(2), _item(4)];

      await _pump(tester, items: stored, total: 8);
      expect(find.text('3 / 8'), findsOneWidget);

      await _pump(tester, items: stored, total: 8, initialIndex: 1);
      expect(find.text('5 / 8'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a Live pair deleted as one row shrinks the post by one',
        (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1, type: 'live'), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2 / 3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('2 / 2'), findsOneWidget,
          reason: 'the pair counts as one item, so the total drops by one');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a record opened with deletes already shows the shrunk total',
        (tester) async {
      await _pump(
        tester,
        items: [_item(1), _item(2)],
        total: 3,
        deletedIndices: {0},
      );
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
