// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 59: a post the floating bubble downloaded shows up in the history.
//
// Device report (build 58): a post downloaded with the bubble was in 「最近保存」
// on the home tab, but the history page never showed it, while an in-app download
// did. The database and the log had it (`HistoryTiming step=recent rows=249 →
// 250`), so the page was dropping it after the read:
//
//  * the page remembered every delete of the session and filtered those posts out
//    of every later read, so a post that was deleted and then downloaded again
//    (`restoreDeleted`) stayed hidden until the app was restarted — the v1.10.x
//    behaviour the report compares against;
//  * a reload requested while another read was running was dropped, so a resume
//    read that overlapped the background engine's write never ran again;
//  * a re-download kept the *old* save time on the record, so the restored post
//    sorted into an old date group far below 今天 instead of where 「最近保存」
//    lists it.
//
// The three modes, the delete guard, the resume read and the save time are all
// pinned here.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_io.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/services/download_manager.dart';
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

const int _postCount = 12;

HistoryRecord _record(
  int index,
  DateTime createdAt, {
  String author = 'author',
  List<int> items = const [1],
}) => HistoryRecord(
  platform: 'xhs',
  postId: 'post-$index',
  postUrl: 'https://www.xiaohongshu.com/explore/post-$index',
  title: 'Post $index',
  authorName: '$author-$index',
  fileCount: items.length,
  createdAt: createdAt,
  itemsJson: jsonEncode([
    for (var i = 0; i < 4; i++)
      {
        'type': 'image',
        'url': 'https://sns-img.xhscdn.com/$index-$i.jpg',
        'width': 1200,
        'height': 1600,
      },
  ]),
  files: [
    for (final item in items)
      HistoryFile(
        filename: 'post-$index-$item.jpg',
        savedAt: createdAt.millisecondsSinceEpoch,
        itemIndex: item,
        mediaId: 'media-$index-$item',
        status: FileStatus.found,
        relativePath: 'Pictures/EasySave/',
      ),
  ],
);

/// One finished download of [items] of the post [index], exactly as the bubble's
/// batch reports it.
DownloadBatch _batch(int index, List<int> items) => DownloadBatch(
  batchId: 'b-$index-${items.join('-')}',
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/post-$index',
  platform: 'xhs',
  postId: 'post-$index',
  authorName: 'author-$index',
  title: 'Post $index',
  jobs: [
    for (final item in items)
      DownloadJob(
        key: 'b-$index-$item',
        label: '图片 $item',
        filename: 'post-$index-$item.jpg',
        urls: ['https://img/$index-$item.jpg'],
        isImage: true,
        itemIndex: item,
      )..state = JobState.done
       ..saved = true
       ..savedTitle = 'post-$index-$item.jpg'
       ..mediaId = 'media-$index-$item',
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

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// Lets the page's own background album sync reach its lookup timeout and
/// finish, so no fake timer outlives the widget tree.
Future<void> flushBackgroundTimers(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 4));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the save time a re-download writes', () {
    late HistoryDb db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
    });

    tearDown(() {
      HistoryDb.resetInstanceForTesting();
    });

    test('a re-download of an existing post takes this save time', () async {
      final old = DateTime.now().subtract(const Duration(days: 10));
      await db.upsert(_record(1, old));

      await writeBatchHistory(db, _batch(1, [1]), recovered: false);

      final stored = (await db.getByPostId('post-1'))!;
      expect(
        DateTime.now().difference(stored.createdAt).inMinutes.abs(),
        lessThan(2),
        reason: 'the post sorts into 今天 like 「最近保存」 lists it',
      );
      // 最近保存 reads the same ordering, so the post is at its top.
      expect((await db.recent()).first.postId, 'post-1');
    });

    test('a first download of a new post lands on today as well', () async {
      await writeBatchHistory(db, _batch(2, [1, 2]), recovered: false);
      final stored = (await db.getByPostId('post-2'))!;
      expect(
        DateTime.now().difference(stored.createdAt).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('a recovery write keeps the earlier save time', () async {
      final old = DateTime.now().subtract(const Duration(days: 10));
      await db.upsert(_record(3, old));

      // Startup recovery / batch adoption: not a user save.
      await writeBatchHistory(db, _batch(3, [1]), recovered: true);

      final stored = (await db.getByPostId('post-3'))!;
      expect(
        stored.createdAt.millisecondsSinceEpoch,
        old.millisecondsSinceEpoch,
        reason: 'a write the user did not ask for is not a new save',
      );
    });

    test('a post deleted and downloaded again is restored with today', () async {
      final old = DateTime.now().subtract(const Duration(days: 10));
      await db.upsert(_record(4, old));
      await db.delete((await db.getByPostId('post-4'))!.id!);

      await writeBatchHistory(db, _batch(4, [1]), recovered: false);

      final restored = (await db.getByPostId('post-4'))!;
      expect(restored.isDeleted, isFalse);
      expect(
        DateTime.now().difference(restored.createdAt).inMinutes.abs(),
        lessThan(2),
      );
    });
  });

  test('a reload asked for during a read is not dropped', () async {
    final controller = HistoryRefreshController();
    addTearDown(controller.dispose);
    var loads = 0;
    final gate = Completer<void>();

    final first = controller.refresh(() async {
      loads++;
      await gate.future;
    }, () async {});
    // The resume read is in flight when another change is reported.
    final second = controller.refresh(() async {
      loads++;
    }, () async {});
    gate.complete();
    await Future.wait([first, second]);

    expect(
      loads,
      2,
      reason: 'the read that started before the change is followed by one that '
          'sees it',
    );
  });

  group('the page after a write by the other engine', () {
    late List<AssetEntity> assets;
    late HistoryDb db;

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
        db = await HistoryDb.instance(dbPath: ':memory:');
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

    Future<void> switchTo(WidgetTester tester, String view) async {
      await tester.tap(find.byKey(ValueKey('view_switcher_$view')));
      await settle(tester);
    }

    /// Exactly what happens when the user comes back to the app after the bubble
    /// finished a download: the activity was stopped, now it is resumed.
    Future<void> returnToTheApp(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
    }

    setUp(() {
      assets = [
        for (var i = 0; i < _postCount; i++)
          AssetEntity(
            id: 'media-$i-1',
            typeInt: AssetType.image.index,
            width: 1200,
            height: 1600,
            title: 'post-$i-1.jpg',
          ),
        AssetEntity(
          id: 'media-999-1',
          typeInt: AssetType.image.index,
          width: 1200,
          height: 1600,
          title: 'post-999-1.jpg',
        ),
        AssetEntity(
          id: 'media-500-1',
          typeInt: AssetType.image.index,
          width: 1200,
          height: 1600,
          title: 'post-500-1.jpg',
        ),
        AssetEntity(
          id: 'media-777-1',
          typeInt: AssetType.image.index,
          width: 1200,
          height: 1600,
          title: 'post-777-1.jpg',
        ),
      ];
    });

    testWidgets('a post the other engine wrote shows in all three modes after '
        'the app resumes', (tester) async {
      final state = await pumpPage(tester);
      expect(find.text('Post 999'), findsNothing);

      // The background engine writes the post while the app is away. Nothing
      // notifies the main engine (its HistoryDb has no listeners there), so only
      // the resume read can deliver it.
      var newId = 0;
      await tester.runAsync(() async {
        await db.upsert(_record(999, DateTime.now(), author: 'newcomer'));
        newId = (await db.getByPostId('post-999'))!.id!;
      });
      await returnToTheApp(tester);

      expect(
        state.recordsForTesting.map((r) => r.postId),
        contains('post-999'),
        reason: 'the read picked the new row up',
      );
      expect(find.text('Post 999'), findsOneWidget);

      await switchTo(tester, 'all');
      expect(
        find.byKey(ValueKey('all-$newId-1')),
        findsOneWidget,
        reason: '全部 shows the new item',
      );

      await switchTo(tester, 'creators');
      expect(
        find.text('newcomer-999'),
        findsOneWidget,
        reason: '创作者 shows the new creator',
      );
      await flushBackgroundTimers(tester);
    });

    testWidgets('a post deleted here and downloaded again is back in 今天',
        (tester) async {
      final state = await pumpPage(tester);
      final old = await tester.runAsync(() async {
        final record = _record(
          500,
          DateTime.now().subtract(const Duration(days: 10)),
          author: 'old',
        );
        await db.upsert(record);
        return (await db.getByPostId('post-500'))!;
      });
      await returnToTheApp(tester);
      expect(
        state.postGroupsForTesting
            .where((entry) => entry.postId == 'post-500')
            .single
            .group,
        isNot('今天'),
        reason: 'the old post sits in its old date group',
      );

      // The user deletes it on the history page.
      await tester.runAsync(() => state.deleteRecordsForTesting([old!]));
      await settle(tester);
      expect(find.text('Post 500'), findsNothing);

      // The bubble downloads the same post again: the record is restored.
      await tester.runAsync(
        () => writeBatchHistory(db, _batch(500, [1]), recovered: false),
      );
      await returnToTheApp(tester);

      final entry = state.postGroupsForTesting
          .where((e) => e.postId == 'post-500')
          .single;
      expect(
        entry.group,
        '今天',
        reason: 'the re-download is a save today, exactly like 「最近保存」',
      );
      expect(
        state.postGroupsForTesting.first.postId,
        'post-500',
        reason: 'newest save first',
      );
      expect(find.text('Post 500'), findsOneWidget);
      await flushBackgroundTimers(tester);
    });

    testWidgets('an in-app save updates the mode in view', (tester) async {
      final state = await pumpPage(tester);

      // The preview page writes through the same engine and bumps the revision.
      await tester.runAsync(
        () => writeBatchHistory(db, _batch(777, [1]), recovered: false),
      );
      HostBridge.historyRevision.value++;
      await settle(tester);

      expect(find.text('Post 777'), findsOneWidget);
      expect(
        state.pendingModeUpdatesForTesting,
        isEmpty,
        reason: 'the mode in view is never pending',
      );
      expect(find.byType(WaterfallPostCard), findsWidgets);
      await flushBackgroundTimers(tester);
    });
  });
}
