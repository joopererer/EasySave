// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 6: the counter reads "this browser" and "the post" at once.
//
// The first number follows what the viewer shows -- items on this device and the
// placeholders of the ones that are gone -- so a delete shrinks it at once and
// an undo restores it. The number in brackets is where the item sits in the
// original post: it does not move with deletes and only follows a successful
// re-parse. When the two agree, only the first one is shown.

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
  int? total,
  int initialIndex = 0,
  Set<int> deletedIndices = const <int>{},
  Future<GalleryBrowserRefresh?> Function(Set<int>)? onRedownloadItems,
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
            GalleryBrowserItemDeletion(ok: true, undo: () async {}),
        onRedownloadItems: onRedownloadItems,
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

/// The button that downloads the page again: batch 5 keyed it
/// `redownload_current`, batch 6 `redownload`.
Future<void> _tapRedownload(WidgetTester tester) async {
  final current = find.byKey(const Key('redownload'));
  await tester.tap(
    current.evaluate().isNotEmpty
        ? current
        : find.byKey(const Key('redownload_current')),
  );
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

  group('the two numbers', () {
    test('a fully saved post shows a single number', () {
      final position = browserPositionFor(
        listIndex: 1,
        listLength: 3,
        itemIndex: 1,
        postTotal: 3,
      );
      expect(position.label, '2/3');
      expect(position.showsOrigin, isFalse);
      expect(position.fullLabel, '2/3');
    });

    test('a partially saved post shows both numbers', () {
      // Only the 3rd, 5th and 7th pictures of eight are on this device.
      final position = browserPositionFor(
        listIndex: 1,
        listLength: 3,
        itemIndex: 4,
        postTotal: 8,
      );
      expect(position.label, '2/3');
      expect(position.originLabel, '5/8');
      expect(position.fullLabel, '2/3 (5/8)');
    });

    test('an original place the post no longer reaches is a dash', () {
      final position = browserPositionFor(
        listIndex: 0,
        listLength: 2,
        itemIndex: 5,
        postTotal: 4,
      );
      expect(position.originLabel, '—/4');
      expect(position.fullLabel, '1/2 (—/4)');
    });

    test('the browser position never runs past what it shows', () {
      final position = browserPositionFor(
        listIndex: 9,
        listLength: 2,
        itemIndex: 0,
        postTotal: 2,
      );
      expect(position.label, '2/2');
    });

    test('a deleted Live pair is one item of the post', () {
      final files = [
        _row(1, FileStatus.found, mediaId: '11'),
        _row(2, FileStatus.deleted, mediaId: '21'),
        _row(2, FileStatus.deleted, mediaId: '22', image: false),
      ];
      expect(deletedItemIndices(files), <int>{1});
    });
  });

  group('the viewer', () {
    testWidgets('a fully saved post hides the second number', (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2/3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('partially saved items keep their place in the post', (
      tester,
    ) async {
      final stored = [_item(2), _item(4), _item(6)];

      await _pump(tester, items: stored, total: 8);
      expect(find.text('1/3 (3/8)'), findsOneWidget);

      await _pump(tester, items: stored, total: 8, initialIndex: 1);
      expect(find.text('2/3 (5/8)'), findsOneWidget);

      await _pump(tester, items: stored, total: 8, initialIndex: 2);
      expect(find.text('3/3 (7/8)'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting the first item shrinks the browser side only', (
      tester,
    ) async {
      await _pump(tester, items: [_item(0), _item(1), _item(2)], total: 3);
      expect(find.text('1/3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('1/2 (2/3)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting a middle item keeps the post number', (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2/3'), findsOneWidget);

      await _deleteCurrent(tester);

      expect(find.text('2/2 (3/3)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting the last item steps back to the new end', (
      tester,
    ) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2)],
        total: 3,
        initialIndex: 2,
      );

      await _deleteCurrent(tester);

      expect(find.text('2/2 (2/3)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('undo puts both numbers back', (tester) async {
      await _pump(tester, items: [_item(0), _item(1), _item(2)], total: 3);

      await _deleteCurrent(tester);
      expect(find.text('1/2 (2/3)'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();

      expect(find.text('1/3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an item that is not on this device still counts', (
      tester,
    ) async {
      await _pump(
        tester,
        items: [_item(0), _item(1, missing: true), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('不在本机'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a Live pair counts once', (tester) async {
      await _pump(
        tester,
        items: [_item(0), _item(1, type: 'live'), _item(2)],
        total: 3,
        initialIndex: 1,
      );
      expect(find.text('2/3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a record opened with deletes keeps the post numbering', (
      tester,
    ) async {
      await _pump(
        tester,
        items: [_item(1), _item(2)],
        total: 3,
        deletedIndices: {0},
      );
      expect(find.text('1/2 (2/3)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a re-parse that lost items dashes out the place', (
      tester,
    ) async {
      await _pump(
        tester,
        items: [_item(0), _item(1), _item(2), _item(3)],
        total: 4,
        initialIndex: 3,
        onRedownloadItems: (indices) async => GalleryBrowserRefresh(
          items: [_item(0), _item(1, missing: true)],
          postTotal: 2,
        ),
      );
      expect(find.text('4/4'), findsOneWidget);

      // A re-download of the selected page re-parses the post.
      await tester.tap(find.byKey(const Key('browser_select_toggle')));
      await tester.pumpAndSettle();
      await _tapRedownload(tester);

      expect(
        find.text('2/2'),
        findsOneWidget,
        reason: 'the page keeps what it can; the post is two items now',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}