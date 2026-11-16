// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: every local thumbnail request uses one of two sizes.
//
// Before this the history cover asked for 400, the creator card's four cells
// 400, the viewer's strip 120 and the parse page's candidate grid 150, so the
// same file was decoded at three different sizes and a picture seen in one
// surface was a cache miss in another. Now:
//
//   small  (160) — creator 2x2 thumbs, the viewer's thumbnail strip, the parse
//                  page's candidate grid;
//   medium (400) — the 帖子 and 全部 waterfall covers (and the row layout).
//
// These tests pin both ends: the tiers themselves, and the size each surface
// really asks the image provider for.

import 'dart:typed_data';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/local_thumbnail_tiers.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sizes the widgets under test asked for.
List<ThumbnailSize> _asked = <ThumbnailSize>[];

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1200,
  height: 1600,
  title: '$id.jpg',
);

HistoryRecord _record({String author = 'a'}) => HistoryRecord(
  platform: 'xhs',
  postId: 'p1',
  postUrl: 'https://example.test/p1',
  title: 'Post',
  authorName: author,
  fileCount: 4,
  createdAt: DateTime(2026, 1, 1),
  files: [
    for (var i = 1; i <= 4; i++)
      HistoryFile(
        filename: 'f_$i.jpg',
        savedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
        itemIndex: i,
        mediaId: 'm$i',
        status: FileStatus.found,
        relativePath: 'Pictures/EasySave/',
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _asked = <ThumbnailSize>[];
    VerifiedAssetImage.resetKnownPresentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (asset, original, size) {
      _asked.add(size);
      return MemoryImage(Uint8List.fromList(_onePixelPng));
    };
    final locator = GalleryLocatorService.instance..resetForTesting();
    final assets = [for (var i = 1; i <= 4; i++) _asset('m$i')];
    locator.permissionReaderForTesting = () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => assets;
    locator.presenceProbeForTesting = (_) async => true;
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: assets,
    );
  });

  tearDown(() {
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
  });

  test('the two tiers are the ones the report names', () {
    expect(LocalThumbnailTiers.small.width, 160);
    expect(LocalThumbnailTiers.small.height, 160);
    expect(LocalThumbnailTiers.medium.width, 400);
    expect(LocalThumbnailTiers.medium.height, 400);
  });

  test('VerifiedAssetImage defaults to the medium tier', () {
    final widget = VerifiedAssetImage(
      _asset('m1'),
      fallback: const SizedBox.shrink(),
    );
    expect(widget.thumbnailSize, LocalThumbnailTiers.medium);
  });

  testWidgets('a history cover asks for the medium tier', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HistoryThumb(record: _record(), itemIndex: 1)),
      ),
    );
    await tester.pump();

    expect(_asked, isNotEmpty);
    expect(_asked.first, LocalThumbnailTiers.medium);
  });

  testWidgets("a creator card's cells ask for the small tier", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              height: 250,
              child: CreatorCard(
                authorName: 'author',
                platform: 'xhs',
                savedDisplayName: '小红书',
                postCount: 1,
                itemCount: 4,
                thumbs: [
                  for (var i = 1; i <= 4; i++) HistThumbRef(_record(), i),
                ],
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_asked, isNotEmpty);
    expect(
      _asked.every((size) => size == LocalThumbnailTiers.small),
      isTrue,
      reason: 'every cell of the 2x2 grid uses the small tier',
    );
  });

  testWidgets("the viewer's thumbnail strip asks for the small tier", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [
            GalleryBrowserItem(
              index: 0,
              type: 'image',
              url: 'https://www.example.com/a.jpg',
              asset: _asset('m1'),
              status: FileStatus.found,
            ),
            GalleryBrowserItem(
              index: 1,
              type: 'image',
              url: 'https://www.example.com/b.jpg',
              asset: _asset('m2'),
              status: FileStatus.found,
            ),
          ],
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: 'https://www.xiaohongshu.com/explore/1',
        ),
      ),
    );
    await tester.pump();

    expect(
      _asked,
      contains(LocalThumbnailTiers.small),
      reason: 'the strip uses the small tier',
    );
  });
}

const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
