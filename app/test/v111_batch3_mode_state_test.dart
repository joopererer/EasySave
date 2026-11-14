// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: switching 帖子 / 全部 / 创作者 no longer throws a mode away.
//
// A mode is created the first time it is entered and remembered afterwards.
// Coming back finds the same scroll offset (its own controller plus
// PageStorage) and the same decoded thumbnails (the image cache), while a
// hidden mode has nothing left in the tree at all: it cannot issue a thumbnail
// request and cannot react to a refresh. A data change that happens while it is
// hidden is applied the moment it is switched back to.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/services/settings.dart';
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

const int _postCount = 30;

HistoryRecord _record(
  int index,
  DateTime createdAt, {
  String author = 'author',
}) => HistoryRecord(
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

/// An image provider that never produces a frame, so a thumbnail request stays
/// in flight exactly as long as its card is mounted.
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

/// Lets the page read its records and lay the cards out.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late List<AssetEntity> assets;

  void installHarness(WidgetTester tester) {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    ThumbnailDiagnostics.instance.resetForTesting();
    VerifiedAssetImage.resetKnownPresentForTesting();

    final locator = GalleryLocatorService.instance;
    locator.permissionReaderForTesting = () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => assets;
    locator.presenceProbeForTesting = (_) async => true;
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: assets,
    );
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (asset, original, size) =>
        _NeverLoadingProvider(asset.id);
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
      VerifiedAssetImage.providerForTesting = null;
      VerifiedAssetImage.existenceForTesting = null;
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
      ThumbnailDiagnostics.instance.resetForTesting();
      HostBridge.historyRevision.value = 0;
    });
  }

  Future<HistoryPageState> pumpPage(WidgetTester tester) async {
    installHarness(tester);
    final now = DateTime.now();
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      for (var i = 0; i < _postCount; i++) {
        await db.upsert(_record(i, now.subtract(Duration(seconds: i))));
      }
    });
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await settle(tester);
    return tester.state<HistoryPageState>(find.byType(HistoryPage));
  }

  Future<void> switchTo(WidgetTester tester, HistoryView view) async {
    await tester.tap(find.byKey(ValueKey('view_switcher_${view.name}')));
    await settle(tester);
  }

  double offsetOf(WidgetTester tester, HistoryView view) {
    final scope = find.byKey(ValueKey('history_view_${view.name}'));
    final scrollable = find.descendant(
      of: scope,
      matching: find.byType(Scrollable),
    );
    return tester.state<ScrollableState>(scrollable.first).position.pixels;
  }

  setUp(() {
    assets = [
      for (var i = 0; i < _postCount; i++)
        AssetEntity(
          id: 'media-$i',
          typeInt: AssetType.image.index,
          width: 1200,
          height: 1600,
          title: '$i.jpg',
        ),
      // The record added mid-test is on this device too, so no CDN cover is
      // fetched (a stray network future would outlive the widget tree).
      AssetEntity(
        id: 'media-999',
        typeInt: AssetType.image.index,
        width: 1200,
        height: 1600,
        title: '999.jpg',
      ),
    ];
  });

  testWidgets('a mode is created on first entry and remembered afterwards', (
    tester,
  ) async {
    final state = await pumpPage(tester);
    expect(state.keptModesForTesting, {HistoryView.posts});

    await switchTo(tester, HistoryView.creators);
    expect(state.keptModesForTesting, {HistoryView.posts, HistoryView.creators});
    expect(find.byType(CreatorCard), findsWidgets);

    await switchTo(tester, HistoryView.posts);
    expect(state.keptModesForTesting, {HistoryView.posts, HistoryView.creators});
  });

  testWidgets('coming back to a mode keeps its scroll position', (tester) async {
    await pumpPage(tester);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await settle(tester);
    final scrolled = offsetOf(tester, HistoryView.posts);
    expect(scrolled, greaterThan(300));

    await switchTo(tester, HistoryView.creators);
    await switchTo(tester, HistoryView.posts);

    expect(
      offsetOf(tester, HistoryView.posts),
      moreOrLessEquals(scrolled, epsilon: 0.5),
      reason: 'the mode came back where it was left',
    );
    expect(find.byType(WaterfallPostCard), findsWidgets,
      reason: 'the mode is usable straight away, not empty',
    );
  });

  testWidgets('a hidden mode is not in the tree, gets no request, and catches '
      'up when it comes back', (tester) async {
    final state = await pumpPage(tester);

    await switchTo(tester, HistoryView.creators);
    expect(find.byType(CreatorCard), findsWidgets);
    expect(
      state.pendingModeUpdatesForTesting,
      isNot(contains(HistoryView.creators)),
      reason: 'a mode that is in view is never pending',
    );

    await switchTo(tester, HistoryView.posts);
    expect(
      find.byType(CreatorCard),
      findsNothing,
      reason: 'a hidden mode has nothing in the tree: it cannot request a '
          'thumbnail or rebuild',
    );
    final issuedWhileVisible = ThumbnailDiagnostics.instance.counters.issued;

    // A record arrives while 创作者 is hidden.
    await tester.runAsync(() async {
      final db = await HistoryDb.instance();
      await db.upsert(
        _record(999, DateTime.now(), author: 'newcomer'),
      );
    });
    HostBridge.historyRevision.value++;
    await settle(tester);

    expect(
      state.pendingModeUpdatesForTesting,
      contains(HistoryView.creators),
      reason: 'the hidden mode owes itself a rebuild it has not done',
    );
    expect(find.byType(CreatorCard), findsNothing);
    expect(
      ThumbnailDiagnostics.instance.counters.issued - issuedWhileVisible,
      lessThanOrEqualTo(4),
      reason: 'only the visible mode rebuilt — at most its own cards were '
          're-issued; a rebuilt hidden mode would have added a screenful',
    );

    // Switching back applies the change.
    await switchTo(tester, HistoryView.creators);
    expect(
      state.pendingModeUpdatesForTesting,
      isNot(contains(HistoryView.creators)),
    );
    expect(
      find.text('newcomer-999'),
      findsWidgets,
      reason: 'the new author is there when the mode comes back',
    );
  });
}
