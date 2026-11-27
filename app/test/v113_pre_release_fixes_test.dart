import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_browser_flow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
  });

  tearDown(() {
    HistoryDb.resetInstanceForTesting();
  });

  test('new pipeline video writes HistoryFile(isImage: false) and viewer resolves video type', () async {
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
      ..mediaId = '8801'
      ..savedTitle = '6b08096e_1.mp4'
      ..relativePath = 'Movies/EasySave/'
      ..fileBytes = 123456;

    final batch = DownloadBatch(
      batchId: 'b-vid',
      album: 'EasySave',
      platform: 'xhs',
      postId: '6b08096e000000002a019d88',
      postUrl: 'https://www.xiaohongshu.com/explore/6b08096e000000002a019d88',
      source: DownloadBatch.sourceMain,
      jobs: [job],
      pipeline: DownloadBatch.pipelineTransfer,
      itemsJson: jsonEncode([
        {'type': 'video', 'url': 'https://sns-video-bd.xhscdn.com/6b08096e.mp4'},
      ]),
    );

    final db = await HistoryDb.instance();
    await writeBatchHistory(db, batch, recovered: false);

    final record = await db.getByPostId('6b08096e000000002a019d88', platform: 'xhs');
    expect(record, isNotNull);
    expect(record!.files.single.isImage, isFalse);

    final built = await savedBrowserItems(
      record: record,
      files: record.visibleFiles,
      post: record.toPost(),
      locate: (f) async => AssetEntity(
        id: f.mediaId!,
        typeInt: AssetType.video.index,
        width: 1080,
        height: 1920,
        duration: 15,
        title: f.filename,
      ),
    );
    expect(built.items.single.type, 'video');
    expect(built.items.single.isGif, isFalse);
  });

  test('deleting the only item of a single-item post removes the post record', () async {
    final db = await HistoryDb.instance();
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'single-img-post',
        postUrl: 'https://www.xiaohongshu.com/explore/single-img-post',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'only.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: '7001',
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
        ],
      ),
      restoreDeleted: true,
      userSave: true,
      source: 'test',
    );

    final record = (await db.getByPostId('single-img-post'))!;
    final outcome = await deleteBrowserItemForRecord(
      record,
      GalleryBrowserItem(index: 0, type: 'image', url: ''),
      deleteAlbumFiles: false,
    );
    expect(outcome?.ok, isTrue);

    final remaining = await db.recent(limit: 20);
    expect(remaining.any((r) => r.postId == 'single-img-post'), isFalse);
  });

  test('deleting all items vs partial items of a multi-item post', () async {
    final db = await HistoryDb.instance();
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'multi-img-post',
        postUrl: 'https://www.xiaohongshu.com/explore/multi-img-post',
        fileCount: 3,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: '1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: '7101',
            itemIndex: 1,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: '2.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: '7102',
            itemIndex: 2,
            isImage: true,
            status: FileStatus.found,
          ),
          HistoryFile(
            filename: '3.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: '7103',
            itemIndex: 3,
            isImage: true,
            status: FileStatus.found,
          ),
        ],
      ),
      restoreDeleted: true,
      userSave: true,
      source: 'test',
    );

    final initial = (await db.getByPostId('multi-img-post'))!;
    final partial = await deleteBrowserItemsForRecord(
      initial,
      [GalleryBrowserItem(index: 0, type: 'image', url: '')],
      deleteAlbumFiles: false,
    );
    expect(partial.ok, isTrue);

    final afterPartial = await db.recent(limit: 20);
    final kept = afterPartial.firstWhere((r) => r.postId == 'multi-img-post');
    expect(kept.visibleFiles.length, 2);

    final deleteRest = await deleteBrowserItemsForRecord(
      kept,
      [
        GalleryBrowserItem(index: 1, type: 'image', url: ''),
        GalleryBrowserItem(index: 2, type: 'image', url: ''),
      ],
      deleteAlbumFiles: false,
    );
    expect(deleteRest.ok, isTrue);

    final afterAll = await db.recent(limit: 20);
    expect(afterAll.any((r) => r.postId == 'multi-img-post'), isFalse);
  });
}

