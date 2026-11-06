import 'dart:convert';
import 'dart:typed_data';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    locator.resetForTesting();
    MediaHeaderService.headerReader = (_, _) async => Uint8List(0);
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: [
        AssetEntity(
          id: 'saved-first',
          typeInt: AssetType.image.index,
          width: 100,
          height: 100,
          title: 'xhs_partial-post_1.jpg',
        ),
      ],
    );
  });
  tearDown(() {
    DownloadManager.instance.clearBatchesForTesting();
    MediaHeaderService.headerReader = null;
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  HistoryFile missingSecond() =>
      HistoryFile(filename: 'xhs_partial-post_2.jpg', savedAt: 1, itemIndex: 2);

  test('synchronous local lookup never fills missing item 2 with item 1', () {
    expect(locator.locateAsset(missingSecond(), 'partial-post'), isNull);
  });

  test(
    'asynchronous local lookup never fills missing item 2 with item 1',
    () async {
      expect(
        await locator.locateAssetAsync(
          missingSecond(),
          'partial-post',
          platform: 'xhs',
        ),
        isNull,
      );
    },
  );

  test(
    'matching post provenance cannot override a different itemIndex',
    () async {
      final origin = XmpProvenance(
        schema: 'easysave',
        assetId: 'first-origin',
        capturedAt: DateTime.utc(2026),
        metadataDate: DateTime.utc(2026),
        capturedBy: 'EasySave/1.10.0',
        platform: 'xiaohongshu',
        sourceId: 'partial-post',
        itemIndex: 1,
        itemCount: 9,
      );
      MediaHeaderService.headerReader = (_, _) async =>
          writeJpegXmp(Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]), origin);
      expect(
        await locator.locateAssetAsync(
          missingSecond(),
          'partial-post',
          platform: 'xhs',
        ),
        isNull,
      );
    },
  );

  test(
    'three selected imports retain three physical rows after previous failure',
    () async {
      final batch = DownloadBatch(
        batchId: 'selected-three',
        album: 'EasySave',
        platform: 'xhs',
        postId: 'partial-post',
        postUrl: 'https://www.xiaohongshu.com/explore/partial-post',
        postItemCount: 9,
        itemsJson: jsonEncode([
          for (var index = 1; index <= 9; index++)
            {'type': 'image', 'url': 'https://img.example/$index.jpg'},
        ]),
        jobs: [
          for (final index in [2, 5, 8])
            DownloadJob(
              key: 'selected-$index',
              label: 'Image $index',
              filename: 'partial-post_$index.jpg',
              urls: ['https://img.example/$index.jpg'],
              isImage: true,
              itemIndex: index,
            )..state = JobState.failed,
        ],
      );
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);
      expect((await db.getByPostId(batch.postId))!.files, isEmpty);
      for (final job in batch.jobs) {
        job
          ..state = JobState.done
          ..saved = true
          ..mediaId = 'saved-${job.itemIndex}';
      }
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostId(batch.postId))!;
      expect(record.fileCount, 3);
      expect(record.files.map((file) => file.itemIndex), [2, 5, 8]);
      expect(deletableMediaFor([record]), hasLength(3));
    },
  );

  test('successful local item clears retained failed batch state', () async {
    final manager = DownloadManager.instance;
    manager.clearBatchesForTesting();
    final batch = DownloadBatch(
      batchId: 'old-failure',
      album: 'EasySave',
      platform: 'xhs',
      postId: 'recovered-post',
      postUrl: 'https://example.test/recovered-post',
      jobs: [
        DownloadJob(
            key: 'failed-1',
            label: 'Image 1',
            filename: 'saved.jpg',
            urls: ['https://img.example/1.jpg'],
            isImage: true,
            itemIndex: 1,
          )
          ..state = JobState.failed
          ..error = 'network failure',
      ],
    );
    manager.setBatchForTesting(batch);
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: batch.postId,
        postUrl: batch.postUrl,
        fileCount: 1,
        createdAt: DateTime(2026),
        files: [
          HistoryFile(
            filename: 'saved.jpg',
            savedAt: 1,
            itemIndex: 1,
            mediaId: 'saved-1',
            status: FileStatus.found,
          ),
        ],
      ),
    );
    final current = (await manager.liveBatches()).single;
    expect(current.failedCount, 0);
    expect(current.succeeded, 1);
    expect(current.jobs.single.error, isNull);
    expect(current.jobs.single.mediaId, 'saved-1');
  });

  test(
    'verified scan removes inferred missing rows but retains provenance evidence',
    () async {
      final files = [
        HistoryFile(
          filename: 'saved.jpg',
          savedAt: 1,
          itemIndex: 1,
          mediaId: 'saved-1',
          status: FileStatus.found,
        ),
        HistoryFile(filename: 'phantom.jpg', savedAt: 1, itemIndex: 2),
        HistoryFile(
          filename: 'deleted.jpg',
          savedAt: 1,
          itemIndex: 3,
          assetId: 'real-origin',
          status: FileStatus.found,
        ),
      ];
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'scan-post',
          postUrl: 'https://example.test/scan-post',
          fileCount: 3,
          createdAt: DateTime(2026),
          files: files,
        ),
      );
      final original = (await db.getByPostId('scan-post'))!;
      await db.syncScannedFiles(original.id!, original.files, [
        files.first,
        files[1].copyWith(status: FileStatus.notFound),
        files[2].copyWith(status: FileStatus.notFound),
      ]);
      final repaired = (await db.getByPostId('scan-post'))!;
      expect(repaired.files.map((file) => file.itemIndex), [1, 3]);
      expect(repaired.savedFiles.map((file) => file.itemIndex), [1]);
      expect(repaired.fileCount, 1);
      expect(deletableMediaFor([repaired]), hasLength(1));
    },
  );

  test(
    'matching asset ID cannot override conflicting original item index',
    () async {
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [
          AssetEntity(
            id: 'corrupt-index',
            typeInt: AssetType.image.index,
            width: 100,
            height: 100,
            title: 'xhs_partial-post_2.jpg',
          ),
        ],
      );
      final origin = XmpProvenance(
        schema: 'easysave',
        assetId: 'same-asset-id',
        capturedAt: DateTime.utc(2026),
        metadataDate: DateTime.utc(2026),
        capturedBy: 'EasySave/1.10.0',
        platform: 'xiaohongshu',
        sourceId: 'partial-post',
        itemIndex: 1,
        itemCount: 9,
      );
      MediaHeaderService.headerReader = (_, _) async =>
          writeJpegXmp(Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]), origin);
      expect(
        await locator.locateAssetAsync(
          missingSecond().copyWith(assetId: 'same-asset-id'),
          'partial-post',
          platform: 'xhs',
        ),
        isNull,
      );
    },
  );

  test(
    'merging three saved files into nine guesses persists only three saved count',
    () async {
      final guessed = HistoryRecord(
        platform: 'xhs',
        postId: 'count-post',
        postUrl: 'https://example.test/count-post',
        fileCount: 9,
        createdAt: DateTime(2025),
        files: [
          for (var index = 1; index <= 9; index++)
            HistoryFile(
              filename: 'count-post_$index.jpg',
              savedAt: 1,
              itemIndex: index,
            ),
        ],
      );
      await db.upsert(guessed);
      expect((await db.getByPostId('count-post'))!.fileCount, 0);
      await db.upsert(
        HistoryRecord(
          platform: guessed.platform,
          postId: guessed.postId,
          postUrl: guessed.postUrl,
          fileCount: 3,
          createdAt: DateTime(2026),
          files: [
            for (final index in [2, 5, 8])
              HistoryFile(
                filename: 'count-post_$index.jpg',
                savedAt: 2,
                itemIndex: index,
                mediaId: 'actual-$index',
                status: FileStatus.found,
              ),
          ],
        ),
      );
      final merged = (await db.getByPostId('count-post'))!;
      expect(merged.files, hasLength(9));
      expect(merged.savedFiles.map((file) => file.itemIndex), [2, 5, 8]);
      expect(merged.fileCount, 3);
      expect(deletableMediaFor([merged]), hasLength(3));
    },
  );

  test(
    'newer actual import wins an equal-rank inferred duplicate media ID',
    () {
      final repaired = repairHistoryFiles([
        HistoryFile(
          filename: 'guessed_1.jpg',
          savedAt: 1,
          itemIndex: 1,
          mediaId: 'same-physical-file',
        ),
        HistoryFile(
          filename: 'actual_3.jpg',
          savedAt: 9,
          itemIndex: 3,
          mediaId: 'same-physical-file',
        ),
      ])!;
      expect(repaired, hasLength(1));
      expect(repaired.single.itemIndex, 3);
      expect(repaired.single.savedAt, 9);
      expect(repaired.single.filename, 'actual_3.jpg');
    },
  );

  HistoryRecord row(String platform, List<int> indices, DateTime at) =>
      HistoryRecord(
        platform: platform,
        postId: 'shared-id',
        postUrl: 'https://example.test/$platform/shared-id',
        fileCount: indices.length,
        createdAt: at,
        files: [
          for (final index in indices)
            HistoryFile(
              filename: '${platform}_shared-id_$index.jpg',
              savedAt: at.millisecondsSinceEpoch,
              itemIndex: index,
              mediaId: '$platform-$index',
              status: FileStatus.found,
            ),
        ],
      );

  test('identical post IDs on two platforms never merge file rows', () async {
    await db.upsert(row('xhs', [1], DateTime(2025)));
    await db.upsert(row('instagram', [2], DateTime(2026)));
    final xhs = await db.getByPostId('shared-id', platform: 'xhs');
    final instagram = await db.getByPostId('shared-id', platform: 'instagram');
    expect(xhs, isNotNull);
    expect(instagram, isNotNull);
    expect(xhs!.files.map((file) => file.mediaId), ['xhs-1']);
    expect(instagram!.files.map((file) => file.mediaId), ['instagram-2']);
  });

  test(
    'new files advance save time while repeated association preserves it',
    () async {
      final original = DateTime(2024), added = DateTime(2025);
      await db.upsert(row('xhs', [1], original), userSave: true);
      await db.upsert(row('xhs', [2], added), userSave: true);
      expect(
        (await db.getByPostId('shared-id', platform: 'xhs'))!.createdAt,
        added,
      );
      await db.upsert(row('xhs', [1, 2], DateTime(2026)), userSave: true);
      expect(
        (await db.getByPostId('shared-id', platform: 'xhs'))!.createdAt,
        added,
      );
    },
  );
}
