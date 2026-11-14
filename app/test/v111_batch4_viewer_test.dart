// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 4: the viewer of a local post knows three states.
//
// A file the album confirmed as gone shows a placeholder with 「不在本机」 and
// 「重新下载这张」, the top counter reads the item's original position against
// the post's original total, and the bottom bar offers the whole set of missing
// items at once. Deleting one item moves to the next and can be undone.

import 'package:easysave/core/models.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/widgets/decoded_image_keeper.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postId = '2118566677374022101';

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1080,
  height: 1440,
  title: '${_postId}_$id.jpg',
);

HistoryFile _row(int index, FileStatus status, {String? mediaId, bool image = true}) =>
    HistoryFile(
      filename: '${_postId}_$index.${image ? 'jpg' : 'mp4'}',
      savedAt: 1,
      mediaId: mediaId,
      status: status,
      itemIndex: index,
      isImage: image,
    );

HistoryRecord _record(List<HistoryFile> files, {int items = 8}) => HistoryRecord(
  platform: 'xhs',
  postId: _postId,
  postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
  title: 'Viewer',
  fileCount: files.length,
  createdAt: DateTime(2026),
  itemsJson:
      '[${[for (var i = 0; i < items; i++) '{"type":"image","url":"https://sns-img.xhscdn.com/$i.jpg"}'].join(',')}]',
  files: files,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VerifiedAssetImage.resetKnownPresentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
  });

  group('items built from stored rows', () {
    test('a row the album answered as gone becomes a missing item', () async {
      final record = _record([
        _row(1, FileStatus.found, mediaId: '11'),
        _row(2, FileStatus.notFound, mediaId: '12'),
      ]);
      final built = await savedBrowserItems(
        record: record,
        files: record.visibleFiles,
        post: record.toPost(),
        locate: (file) async => file.itemIndex == 1 ? _asset('11') : null,
      );
      expect(built.items, hasLength(2));
      expect(built.items[0].missing, isFalse);
      expect(built.items[0].asset, isNotNull);
      expect(built.items[1].missing, isTrue,
          reason: 'the album answered and the file is gone');
      expect(built.items[1].status, FileStatus.notFound);
    });

    test('a lookup that failed is not a missing item', () async {
      final record = _record([
        _row(1, FileStatus.found, mediaId: '11'),
      ]);
      final built = await savedBrowserItems(
        record: record,
        files: record.visibleFiles,
        post: record.toPost(),
        locate: (file) async => null,
      );
      expect(built.items.single.missing, isFalse,
          reason: 'no answer from the album must not create a placeholder');
    });

    test('a Live photo with one half gone is missing as a whole', () async {
      final still = _row(1, FileStatus.found, mediaId: '21');
      final clip = _row(1, FileStatus.notFound, mediaId: '22', image: false);
      final entries = pairSavedMedia([still, clip]);
      expect(entries.single.isLive, isTrue);
      final record = _record([still, clip]);
      final built = await savedBrowserItems(
        record: record,
        files: record.visibleFiles,
        post: record.toPost(),
        locate: (file) async => file.isImage ? _asset('21') : null,
      );
      expect(built.items.single.missing, isTrue,
          reason: 'the pair is viewed and re-downloaded whole');
    });
  });

  group('the viewer', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    List<GalleryBrowserItem> items() => [
      GalleryBrowserItem(
        index: 0,
        type: 'image',
        url: '',
        asset: _asset('11'),
        filename: '${_postId}_1.jpg',
      ),
      GalleryBrowserItem(
        index: 1,
        type: 'image',
        url: '',
        missing: true,
        status: FileStatus.notFound,
        filename: '${_postId}_2.jpg',
      ),
      GalleryBrowserItem(
        index: 2,
        type: 'image',
        url: '',
        missing: true,
        status: FileStatus.notFound,
        filename: '${_postId}_3.jpg',
      ),
    ];

    testWidgets('a missing item shows the placeholder and its own button',
        (tester) async {
      var asked = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: items(),
            initialIndex: 1,
            originalTotal: 8,
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
            onRedownloadItems: (indices) async {
              asked = indices;
              return null;
            },
          ),
        ),
      );
      await settle(tester);

      expect(find.text('不在本机'), findsOneWidget);
      expect(find.text('重新下载这张'), findsOneWidget);
      // The position is the item's own place in the post, not its list slot.
      expect(find.text('2 / 8'), findsOneWidget);
      expect(find.text('重新下载缺失的 2 张'), findsOneWidget);

      await tester.tap(find.text('重新下载这张'));
      await settle(tester);
      expect(asked, {1}, reason: 'one item, by its original index');

      await tester.tap(find.text('重新下载缺失的 2 张'));
      await settle(tester);
      expect(asked, {1, 2}, reason: 'the whole missing set at once');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a post whose items are all missing still opens', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: [
              for (final index in [0, 1])
                GalleryBrowserItem(
                  index: index,
                  type: 'image',
                  url: '',
                  missing: true,
                  status: FileStatus.notFound,
                ),
            ],
            originalTotal: 2,
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
            onRedownloadItems: (indices) async => null,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('不在本机'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('重新下载缺失的 2 张'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('deleting one item moves on to the next and can be undone',
        (tester) async {
      var deletions = 0;
      var undoable = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: items(),
            originalTotal: 3,
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
            onDeleteItem: (item, {required bool deleteAlbumFiles}) async {
              deletions++;
              expect(deleteAlbumFiles, isFalse, reason: 'the default is record only');
              expect(item.index, 0);
              return GalleryBrowserItemDeletion(
                ok: true,
                message: '已删除这张',
                undo: () async {
                  undoable++;
                },
              );
            },
          ),
        ),
      );
      await settle(tester);
      expect(find.text('1 / 3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('delete_item')));
      await settle(tester);
      expect(find.text('仅删除记录'), findsOneWidget);
      expect(find.text('同时删除相册文件'), findsOneWidget);

      await tester.tap(find.text('仅删除记录'));
      await settle(tester);
      expect(deletions, 1);
      // The next item takes the place of the deleted one.
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('不在本机'), findsOneWidget);

      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(undoable, 1);
      expect(find.text('1 / 3'), findsOneWidget,
          reason: 'the deleted item is back in place');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a delete that kept the file says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: items(),
            originalTotal: 3,
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
            onDeleteItem: (item, {required bool deleteAlbumFiles}) async {
              expect(deleteAlbumFiles, isTrue);
              return const GalleryBrowserItemDeletion(
                ok: true,
                message: '相册文件未删除（已取消或系统不允许），已仅删除记录',
              );
            },
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('delete_item')));
      await settle(tester);
      await tester.tap(find.text('同时删除相册文件'));
      await settle(tester);
      expect(
        find.text('相册文件未删除（已取消或系统不允许），已仅删除记录'),
        findsOneWidget,
      );
      expect(find.text('撤销'), findsNothing,
          reason: 'nothing was removed from the album, but the record change is '
              'not offered as undoable by a caller that returned no closure');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
