// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 2: the history waterfalls only build what the viewport shows.
//
// Build 49 flooded the local thumbnail pipeline: 625 timeout lines and an
// in-flight peak of 416 native thumbnail requests while about a dozen cards
// were on screen. A 200-post date group built all 200 cards (each mounted
// card starts exactly one local thumbnail request), because the group had to
// be measured to know its height.
//
// These tests pin the fix: one group of 200 posts must create only the cards
// near the viewport, the estimated height must be the real card height, and
// scrolling must create the following cards (lazily) without ever having more
// than a screenful of requests in flight.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/thumbnail_diagnostics.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int _postCount = 200;

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1200,
  height: 1600,
  title: '$id.jpg',
);

/// Every card is a 3:4 cover, i.e. one column and a bit per screen: the 200
/// cards of the group are ~100 screens tall together.
HistoryRecord _record(int index, DateTime createdAt) => HistoryRecord(
  platform: 'xhs',
  postId: 'post-$index',
  postUrl: 'https://example.test/$index',
  title: 'Post $index',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// A provider that never produces a frame, so a thumbnail request stays in
  /// flight exactly as long as its card is mounted.
  setUp(() {
    ThumbnailDiagnostics.instance.resetForTesting();
    VerifiedAssetImage.resetKnownPresentForTesting();
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
  });

  testWidgets('a 200-post group builds only the cards near the viewport, and '
      'scrolling builds the next ones', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    // The album already holds every file, so each built card really does start
    // a local thumbnail request — the device path a flood shows up in.
    final assets = [
      for (var i = 0; i < _postCount; i++) _asset('media-$i'),
    ];
    final locator = GalleryLocatorService.instance;
    locator.permissionReaderForTesting =
        () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => assets;
    locator.presenceProbeForTesting = (_) async => true;
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: assets,
    );
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting =
        (asset, original, size) => _NeverLoadingProvider(asset.id);
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      photos,
      (_) async => 0,
    );
    addTearDown(() async {
      // Disposing the page cancels every per-card deadline.
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        null,
      );
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });
    final now = DateTime.now();
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      // One date group: 200 posts, all today.
      for (var i = 0; i < _postCount; i++) {
        await db.upsert(_record(i, now.subtract(Duration(seconds: i))));
      }
    });
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    List<String> builtIds() => [
      for (final card
          in tester.widgetList<WaterfallPostCard>(
            // Off-stage cards (inside the cache extent) are built too; count
            // them, they are what issues the extra requests.
            find.byType(WaterfallPostCard, skipOffstage: false),
          ))
        card.record.postId,
    ];

    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await settle();

    final first = builtIds();
    // A 600px viewport with 3:4 covers holds four cards; the small cache
    // extent may add a couple.
    expect(first, isNotEmpty);
    expect(
      first.length,
      lessThanOrEqualTo(8),
      reason: 'only the visible cards may be built, not all $_postCount',
    );
    // One mounted card starts exactly one local thumbnail request.
    expect(ThumbnailDiagnostics.instance.inflight, first.length);

    // The estimated height is the real one: the layout was computed from the
    // record, and the card on screen really is that tall.
    final card = tester.widget<WaterfallPostCard>(
      find.byType(WaterfallPostCard).first,
    );
    final size = tester.getSize(find.byType(WaterfallPostCard).first);
    expect(
      size.height,
      moreOrLessEquals(waterfallCardHeight(card.record, size.width), epsilon: 0.5),
    );

    // Fast flick downwards, like a user browsing: cards that leave the cache
    // extent are disposed and their thumbnails stop counting.
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -4000),
    );
    await settle();

    final second = builtIds();
    expect(second, isNotEmpty);
    expect(
      second.length,
      lessThanOrEqualTo(8),
      reason: 'scrolling must not build the whole group either',
    );
    expect(
      second.toSet().intersection(first.toSet()),
      isEmpty,
      reason: 'the scrolled-away cards are gone, new ones took their place',
    );
    expect(ThumbnailDiagnostics.instance.inflight, lessThanOrEqualTo(8));
  });
}

/// An image provider that never produces a frame.
class _NeverLoadingProvider extends ImageProvider<_NeverLoadingProvider> {
  _NeverLoadingProvider(this.id);

  final String id;

  @override
  Future<_NeverLoadingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NeverLoadingProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverLoadingProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
