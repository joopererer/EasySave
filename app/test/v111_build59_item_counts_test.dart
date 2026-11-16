// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 59: every user-visible number counts items, never files.
//
// Device report (build 58): the delete sheet said 「同时删除相册中的 11 个文件」
// for a post with 8 items, three of them Live photos (8 items = 11 files). The
// album delete still removes both halves of a Live photo; only the sentence the
// user reads counts 8.
//
// Pinned here: the counting helpers, the delete sheet, the history page's own
// statistics and cards, the 、创作者 card, the backup preview and the restore
// summary.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/widgets/delete_records_sheet.dart';
import 'package:easysave/widgets/restore_progress_dialog.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Live photo items of the 8-item post: the still and the clip of each are two
/// files but one item.
const Set<int> _liveItems = {2, 4, 6};

HistoryFile _still(int item, int savedAt) => HistoryFile(
  filename: 'post_$item.jpg',
  savedAt: savedAt,
  mediaId: 'media-$item-i',
  status: FileStatus.found,
  itemIndex: item,
  isImage: true,
  pairId: _liveItems.contains(item) ? 'post#$item' : null,
);

HistoryFile _clip(int item, int savedAt) => HistoryFile(
  filename: 'post_$item.mp4',
  savedAt: savedAt,
  mediaId: 'media-$item-v',
  status: FileStatus.found,
  itemIndex: item,
  isImage: false,
  pairId: 'post#$item',
);

/// 8 items, three of them Live photos: 11 files.
HistoryRecord _livePost({DateTime? createdAt}) {
  const savedAt = 1700000000000;
  return HistoryRecord(
    platform: 'xhs',
    postId: '6af7c74e0000000014010400',
    postUrl: 'https://www.xiaohongshu.com/explore/6af7c74e0000000014010400',
    title: 'Live post',
    authorName: 'creator',
    fileCount: 11,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
    itemsJson: jsonEncode([
      for (var i = 0; i < 8; i++)
        {'type': 'image', 'url': 'https://sns-img.xhscdn.com/$i.jpg'},
    ]),
    files: [
      for (var item = 1; item <= 8; item++) _still(item, savedAt),
      for (final item in _liveItems) _clip(item, savedAt),
    ],
  );
}

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

Future<void> flushBackgroundTimers(WidgetTester tester) async {
  // The page's background album sync starts one lookup deadline per file; the
  // loop finishes only after every one of them has run out.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(seconds: 4));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('a Live photo counts once: 8 items are 11 files', () {
    final record = _livePost();
    expect(record.files.length, 11);
    expect(savedMediaEntryCount(record.files), 8);
    expect(savedFileCountFor([record]), 11, reason: 'the album delete names '
        'every file it has to remove');
    expect(savedItemCountFor([record]), 8, reason: 'the sheet counts items');
  });

  test('the album request still names both halves of every Live photo', () {
    final record = _livePost();
    final media = deletableMediaFor([record]);
    expect(media.length, 11);
    expect(deletableItemCountFor([record], media), 8);
  });

  testWidgets('the delete sheet offers items, not files', (tester) async {
    late BuildContext host;
    final record = _livePost();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final future = showDeleteRecordsSheet(
      host,
      recordCount: 1,
      itemCount: savedItemCountFor([record]),
      cancelDownloads: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('同时删除相册中的 8 项'), findsOneWidget);
    expect(
      find.textContaining('11'),
      findsNothing,
      reason: 'no file number reaches the sheet',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the backup preview promises items and the summary reports them', () {
    final record = _livePost();
    final json = jsonEncode({
      'format': BackupData.currentFormat,
      'schemaVersion': BackupData.currentSchemaVersion,
      'formatVersion': BackupData.currentFormatVersion,
      'exportedAt': '2026-01-01T00:00:00+08:00',
      'appVersion': '1.11.0',
      'settings': const <String, dynamic>{},
      'posts': [
        {
          'platform': 'xiaohongshu',
          'sourceId': record.postId,
          'originalUrl': record.postUrl,
          'savedAt': '2026-01-01T00:00:00+08:00',
          'status': 'complete',
          'files': [
            for (final file in record.files)
              {
                'itemIndex': file.itemIndex,
                'mediaType': file.isImage ? 'image' : 'video',
                'filename': file.filename,
                'savedAt': '2026-01-01T00:00:00+08:00',
              },
          ],
        },
      ],
    });
    final preview = BackupService.previewBackup(json);
    expect(preview.fileCount, 11, reason: 'internal count stays per file');
    expect(preview.itemCount, 8, reason: 'the preview counts items');

    final summary = restoreSummaryText(
      ImportResult(
        restoredPosts: 1,
        restoredFiles: 11,
        restoredItems: 8,
        restoredSettings: false,
        notOnDevice: 3,
        notOnDeviceItems: 2,
      ),
    );
    expect(summary, contains('恢复媒体：8 项'));
    expect(summary, contains('不在本机：2 项'));
    expect(summary, isNot(contains('个文件')));
  });

  group('the history page', () {
    late HistoryDb db;

    void installHarness(WidgetTester tester) {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      VerifiedAssetImage.resetKnownPresentForTesting();

      final record = _livePost(createdAt: DateTime.now());
      final locator = GalleryLocatorService.instance;
      locator.permissionReaderForTesting = () async => PermissionState.authorized;
      locator.albumReaderForTesting = () async => [
        for (final file in record.files)
          AssetEntity(
            id: file.mediaId!,
            typeInt: (file.isImage ? AssetType.image : AssetType.video).index,
            width: 1200,
            height: 1600,
            title: file.filename,
          ),
      ];
      locator.presenceProbeForTesting = (_) async => true;
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [
          for (final file in record.files)
            AssetEntity(
              id: file.mediaId!,
              typeInt: (file.isImage ? AssetType.image : AssetType.video).index,
              width: 1200,
              height: 1600,
              title: file.filename,
            ),
        ],
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
      });
    }

    Future<HistoryPageState> pumpPage(WidgetTester tester) async {
      installHarness(tester);
      await tester.runAsync(() async {
        db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.clear();
        await db.upsert(_livePost(createdAt: DateTime.now()));
      });
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await settle(tester);
      return tester.state<HistoryPageState>(find.byType(HistoryPage));
    }

    testWidgets('the top statistics and the post card count items',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('1 个帖子 · 8 项'), findsOneWidget);
      expect(find.textContaining('11 项'), findsNothing);
      expect(find.textContaining('个文件'), findsNothing);
      await flushBackgroundTimers(tester);
    });

    testWidgets('the list row counts items', (tester) async {
      await pumpPage(tester);
      // 瀑布流 → 列表 keeps the first visible post in place.
      await tester.tap(
        find.byIcon(Icons.view_list),
      );
      await settle(tester);
      expect(find.textContaining('8 项 · '), findsOneWidget);
      expect(find.textContaining('个文件'), findsNothing);
      await flushBackgroundTimers(tester);
    });

    testWidgets('the 创作者 card reads 帖 and 项', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
      await settle(tester);
      expect(find.text('1 帖 · 8 项'), findsOneWidget);
      await flushBackgroundTimers(tester);
    });
  });
}
