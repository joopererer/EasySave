// Copyright 2026 EasySave. All rights reserved.
//
// A user who deletes a history record (but keeps the album files) and then
// saves the same post again must get the record back — in every shape the
// preview page's save can take:
//
//   * every selected file is already in the album  -> associate-existing path
//   * some files are in the album, some are missing  -> associate + download
//   * no file is in the album                       -> download batch
//
// Recovery paths (startup, batch adoption) must keep the record deleted.

import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ParsedPost _post(String postId) => ParsedPost(
      platform: 'xhs',
      id: postId,
      url: 'https://www.xiaohongshu.com/explore/$postId',
      author: PostAuthor(name: 'tester'),
      items: [
        MediaItem(type: 'image', url: 'https://img/1.jpg'),
        MediaItem(type: 'image', url: 'https://img/2.jpg'),
      ],
    );

AssetEntity _asset(String id, String title) => AssetEntity(
      id: id,
      typeInt: AssetType.image.index,
      width: 100,
      height: 100,
      title: title,
    );

void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_usersave');
    tempDbPath =
        '${tempDir.path}/usersave_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore cleanup errors
    }
  });

  /// A record the user deleted while keeping the album files.
  Future<HistoryRecord> deletedRecord(String postId) async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: postId,
        postUrl: 'https://www.xiaohongshu.com/explore/$postId',
        fileCount: 2,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(filename: '$postId-1.jpg', savedAt: 0, itemIndex: 0),
          HistoryFile(filename: '$postId-2.jpg', savedAt: 0, itemIndex: 1),
        ],
      ),
    );
    final record = (await db.getByPostId(postId))!;
    await db.delete(record.id!);
    expect(await db.recent(), isEmpty);
    return record;
  }

  DownloadBatch finishedBatch(String postId) => DownloadBatch(
        batchId: 'b-$postId',
        album: 'EasySave',
        postUrl: 'https://www.xiaohongshu.com/explore/$postId',
        platform: 'xhs',
        postId: postId,
        jobs: [
          DownloadJob(
            key: 'b-$postId-0',
            label: '图片 1',
            filename: 'f1.jpg',
            urls: ['https://img/1.jpg'],
            isImage: true,
            itemIndex: 1,
          )..state = JobState.done
            ..saved = true
            ..mediaId = 'media1',
        ],
      );

  group('Re-saving a deleted post restores the record', () {
    test('every selected file already exists (associate-existing path)',
        () async {
      await deletedRecord('all_exist');
      final post = _post('all_exist');
      final matches = {
        0: _asset('m0', 'all_exist-1.jpg'),
        1: _asset('m1', 'all_exist-2.jpg'),
      };

      final associated = await GalleryLocatorService.instance.associateExisting(
        post,
        [0, 1],
        restoreDeleted: true,
        matches: matches,
        db: db,
      );
      expect(associated, 2);

      final restored = await db.getByPostId('all_exist');
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });

    test('some files exist, the rest are downloaded (associate + batch)',
        () async {
      await deletedRecord('partial');
      final post = _post('partial');
      final matches = {0: _asset('m0', 'partial-1.jpg')};

      // The already existing file is associated first ...
      final associated = await GalleryLocatorService.instance.associateExisting(
        post,
        [0],
        restoreDeleted: true,
        matches: matches,
        db: db,
      );
      expect(associated, 1);

      // ... then the missing one is downloaded; the batch writes the history
      // record when it finishes (recovered: false -> restoreDeleted: true).
      await writeBatchHistory(db, finishedBatch('partial'), recovered: false);

      final restored = await db.getByPostId('partial');
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });

    test('no file exists yet (download batch only)', () async {
      await deletedRecord('none_exist');

      await writeBatchHistory(db, finishedBatch('none_exist'), recovered: false);

      final restored = await db.getByPostId('none_exist');
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });

    test('a recovery write still keeps the record deleted', () async {
      await deletedRecord('recovered');

      // Startup recovery / batch adoption must not resurrect it.
      await writeBatchHistory(db, finishedBatch('recovered'), recovered: true);

      final stillDeleted = await db.getByPostId('recovered');
      expect(stillDeleted!.isDeleted, isTrue);
      expect(await db.recent(), isEmpty);
    });
  });
}
