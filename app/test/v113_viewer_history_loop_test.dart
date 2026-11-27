import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DevLog.clear();
    GalleryLocatorService.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
  });

  tearDown(() {
    GalleryLocatorService.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  test('upsert with identical record suppresses DB write and notifyChanged', () async {
    final db = await HistoryDb.instance();
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final record = HistoryRecord(
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      authorName: 'Author',
      title: 'Short Video',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      fileCount: 1,
      createdAt: now,
      files: [
        HistoryFile(
          filename: '6b08096e_1.mp4',
          savedAt: 1700000000000,
          mediaId: '9901',
          status: FileStatus.found,
          itemIndex: 1,
          isImage: false,
          rowVer: 'download',
        ),
      ],
    );

    var notifications = 0;
    db.addListener(() => notifications++);

    await db.upsert(record, source: 'download');
    expect(notifications, 1);

    // Repeating the exact same upsert must be a no-op (0 extra notifications).
    final beforeWrittenCount = DevLog.recentLines(100)
        .where((l) => l.contains('file rows written'))
        .length;
    await db.upsert(record, source: 'download');
    expect(notifications, 1);
    final afterWrittenCount = DevLog.recentLines(100)
        .where((l) => l.contains('file rows written'))
        .length;
    expect(afterWrittenCount, beforeWrittenCount);
  });

  test('syncScannedFiles is idempotent and preserves download-written mediaId', () async {
    final db = await HistoryDb.instance();
    final record = HistoryRecord(
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      fileCount: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      files: [
        HistoryFile(
          filename: '6b08096e_1.mp4',
          savedAt: 1700000000000,
          mediaId: '9901',
          status: FileStatus.found,
          itemIndex: 1,
          isImage: false,
          rowVer: 'download',
        ),
      ],
    );
    await db.upsert(record, source: 'download');
    final saved = (await db.getByPostId('6b08096e000000002a019d88'))!;

    var notifications = 0;
    db.addListener(() => notifications++);

    // Gallery-scan proposing a different mediaId must NOT overwrite download's mediaId.
    final afterFirst = await db.syncScannedFiles(
      saved.id!,
      saved.files,
      [saved.files.single.copyWith(mediaId: '7777', status: FileStatus.found)],
    );
    expect(afterFirst.single.mediaId, '9901');
    expect(notifications, 0);

    // Repeating an identical scan is also a no-op.
    final afterSecond = await db.syncScannedFiles(
      saved.id!,
      afterFirst,
      afterFirst,
    );
    expect(afterSecond.single.mediaId, '9901');
    expect(notifications, 0);
  });

  test('syncRecord keeps present download mediaId and savedBrowserItems resolves video', () async {
    final db = await HistoryDb.instance();
    final locator = GalleryLocatorService.instance;
    final videoAsset = AssetEntity(
      id: '9901',
      typeInt: AssetType.video.index,
      width: 720,
      height: 1280,
      title: '6b08096e_1.mp4',
    );
    locator.hasAccessForTesting = true;
    locator.permissionReaderForTesting = () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => []; // Album list lagging behind MediaStore
    locator.presenceProbeForTesting = (id) async => id == '9901';
    locator.assetByIdForTesting = (id) async => id == '9901' ? videoAsset : null;

    await locator.scanAlbum(force: true);

    final job = DownloadJob(
      key: 'vid-0',
      label: '视频',
      filename: '6b08096e_1.mp4',
      urls: ['https://sns-video-bd.xhscdn.com/6b08096e.mp4'],
      isImage: false,
      itemIndex: 1,
    )
      ..usesNewTransferPipeline = true
      ..transferJobId = 'xfer_vid-0'
      ..state = JobState.done
      ..saved = true
      ..mediaId = '9901'
      ..savedTitle = '6b08096e_1.mp4'
      ..relativePath = 'Movies/EasySave/'
      ..fileBytes = 123456;

    final batch = DownloadBatch(
      batchId: 'b-vid-sync',
      album: 'EasySave',
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      source: DownloadBatch.sourceMain,
      jobs: [job],
      pipeline: DownloadBatch.pipelineTransfer,
      itemsJson: jsonEncode([
        {
          'type': 'video',
          'url': 'https://sns-video-bd.xhscdn.com/6b08096e.mp4',
          'videoUrl': 'https://sns-video-bd.xhscdn.com/6b08096e.mp4',
        },
      ]),
    );
    await writeBatchHistory(db, batch, recovered: false);

    final record = (await db.getByPostId('6b08096e000000002a019d88'))!;
    await locator.syncRecord(record);

    final refreshed = (await db.getByPostId('6b08096e000000002a019d88'))!;
    expect(refreshed.files.single.status, FileStatus.found);
    expect(refreshed.files.single.mediaId, '9901');

    final browser = await savedBrowserItems(
      record: refreshed,
      files: refreshed.files,
      post: refreshed.toPost(),
    );
    expect(browser.items.single.type, 'video');
    expect(browser.items.single.missing, isFalse);
    expect(browser.items.single.status, FileStatus.found);
    expect(browser.items.single.asset?.id, '9901');
  });

  test('DB row rewrite to notFound evicts stale locator cache and logs row_replaced', () async {
    final db = await HistoryDb.instance();
    final locator = GalleryLocatorService.instance;
    final videoAsset = AssetEntity(
      id: '9902',
      typeInt: AssetType.video.index,
      width: 720,
      height: 1280,
      title: '6b08096e_1.mp4',
    );
    locator.hasAccessForTesting = true;
    locator.assetByIdForTesting = (id) async => id == '9902' ? videoAsset : null;

    final record = HistoryRecord(
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      fileCount: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      files: [
        HistoryFile(
          filename: '6b08096e_1.mp4',
          savedAt: 1700000000000,
          mediaId: '9902',
          status: FileStatus.found,
          itemIndex: 1,
          isImage: false,
          rowVer: 'gallery-scan',
        ),
      ],
    );
    await db.upsert(record, source: 'download');
    final saved = (await db.getByPostId('6b08096e000000002a019d88'))!;

    // Populate cache via getAssetByIdAsync.
    expect(await locator.getAssetByIdAsync('9902'), isNotNull);
    expect(locator.getAssetById('9902'), isNotNull);

    DevLog.clear();
    await db.syncScannedFiles(
      saved.id!,
      saved.files,
      [saved.files.single.copyWith(status: FileStatus.notFound)],
    );

    // Cache must be evicted immediately after DB row rewrite.
    expect(locator.getAssetById('9902'), isNull);
    expect(
      DevLog.recentLines(50).any(
        (l) => l.contains('[HIST] row_replaced post=6b08096e000000002a019d88 source=gallery-scan'),
      ),
      isTrue,
    );
  });

  test('video file is never misclassified as image even when postItem.type is image', () async {
    final record = HistoryRecord(
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      fileCount: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      itemsJson: jsonEncode([
        {
          'type': 'image',
          'url': 'https://sns-webpic-qc.xhscdn.com/cover.jpg',
        },
      ]),
      files: [
        HistoryFile(
          filename: '6b08096e_1.mp4',
          savedAt: 1700000000000,
          mediaId: '9903',
          status: FileStatus.found,
          itemIndex: 1,
          isImage: false,
          rowVer: 'download',
        ),
      ],
    );

    final browser = await savedBrowserItems(
      record: record,
      files: record.files,
      post: record.toPost(),
      locate: (_) async => AssetEntity(
        id: '9903',
        typeInt: AssetType.video.index,
        width: 720,
        height: 1280,
        title: '6b08096e_1.mp4',
      ),
    );
    expect(browser.items.single.type, 'video');
    expect(browser.items.single.typeSource, 'isImage');
  });
}

