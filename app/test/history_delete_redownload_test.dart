import 'dart:io';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Deleting a post and downloading it again must never bring the old file rows
/// back. The history may only count rows that were confirmed to exist in the
/// album, and an old file that is still in the album is re-associated through
/// MediaStore when it is downloaded again.
void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('easysave_redownload_');
    tempDbPath = '${dir.path}/history.db';
    HistoryDb.resetInstanceForTesting();
    SiteRegistry.useBuiltin();
    db = await HistoryDb.instance(dbPath: tempDbPath);
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      final dir = file.parent;
      if (await file.exists()) await file.delete();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort cleanup.
    }
  });

  HistoryFile fileRow(int index, {String? mediaId, FileStatus? status}) =>
      HistoryFile(
        filename: 'post_$index.jpg',
        savedAt: 1700000000000 + index,
        mediaId: mediaId ?? 'media-$index',
        itemIndex: index,
        status: status ?? FileStatus.found,
      );

  HistoryRecord record(List<HistoryFile> files) => HistoryRecord(
    platform: 'xhs',
    postId: '6ae36a66000000002a01e77e',
    postUrl: 'https://www.xiaohongshu.com/explore/6ae36a66000000002a01e77e',
    fileCount: files.length,
    createdAt: DateTime(2026, 1, 1),
    files: files,
  );

  /// One finished download of the given item indices, exactly as the overlay's
  /// "选择下载" batch reports them.
  DownloadBatch batchFor(List<int> items) => DownloadBatch(
    batchId: 'b-${items.join('-')}',
    album: 'EasySave',
    postUrl: 'https://www.xiaohongshu.com/explore/6ae36a66000000002a01e77e',
    platform: 'xhs',
    postId: '6ae36a66000000002a01e77e',
    jobs: [
      for (final index in items)
        DownloadJob(
          key: 'b-$index',
          label: '图片 $index',
          filename: 'post_$index.jpg',
          urls: ['https://img/$index.jpg'],
          isImage: true,
          itemIndex: index,
        )..state = JobState.done
         ..saved = true
         ..mediaId = 'media-$index',
    ],
  );

  test('deleting a post clears its file rows so nothing can be restored', () async {
    await db.upsert(record([fileRow(1), fileRow(2), fileRow(3)]));
    final stored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(stored.files.length, 3);

    await db.delete(stored.id!);

    final deleted = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(deleted.isDeleted, isTrue);
    expect(deleted.files, isEmpty);
    expect(deleted.fileCount, 0);
    // Still readable for an undo, but never counted.
    expect(await db.recent(), isEmpty);
  });

  test('re-download after delete keeps only the newly selected items', () async {
    await db.upsert(record([fileRow(1), fileRow(2), fileRow(3), fileRow(4)]));
    await db.delete((await db.getByPostId('6ae36a66000000002a01e77e'))!.id!);

    // The user now picks three different items of the same post.
    await writeBatchHistory(db, batchFor([5, 6, 7]), recovered: false);

    final restored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(restored.isDeleted, isFalse);
    expect(restored.files.map((f) => f.itemIndex).toList(), [5, 6, 7]);
    expect(restored.savedFiles.length, 3);
  });

  test('repeated delete and re-download cycles never grow the file count', () async {
    final selections = [
      [1, 2, 3, 4, 5, 6, 7, 8],
      [1, 2, 3],
      [1, 2, 3, 4],
      [1, 2, 3, 4, 5],
      [1, 2],
    ];
    for (final selection in selections) {
      final existing = await db.getByPostId('6ae36a66000000002a01e77e');
      if (existing != null) await db.delete(existing.id!);
      await writeBatchHistory(db, batchFor(selection), recovered: false);
      final stored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
      expect(
        stored.savedFiles.length,
        selection.length,
        reason: 'selected ${selection.length} items',
      );
      expect(
        stored.files.map((f) => f.itemIndex).toList(),
        selection,
        reason: 'no row from an earlier cycle may survive',
      );
    }
  });

  test('a write merges only with file rows confirmed in the album', () async {
    // The album scan already reported that items 2 and 3 are gone.
    await db.upsert(
      record([
        fileRow(1),
        fileRow(2, status: FileStatus.notFound),
        fileRow(3, status: FileStatus.unknown),
      ]),
    );
    // A new download of item 4 must not adopt the unconfirmed rows.
    await writeBatchHistory(db, batchFor([4]), recovered: false);

    final stored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(stored.files.map((f) => f.itemIndex).toList(), [1, 4]);
    expect(stored.savedFiles.length, 2);
  });

  test('display counts only files confirmed in the album', () async {
    final rec = record([
      fileRow(1),
      fileRow(2, status: FileStatus.unknown),
      fileRow(3, status: FileStatus.notFound),
    ]);
    expect(rec.savedFiles.map((f) => f.itemIndex).toList(), [1]);

    // A row without any album confirmation is not a saved file either.
    final guessed = HistoryFile(
      filename: 'guess.jpg',
      savedAt: 0,
      itemIndex: 2,
      status: FileStatus.unknown,
    );
    expect(isSavedHistoryFile(guessed), isFalse);
  });

  test('overlay selection without thumbnails writes exactly the picked items', () async {
    // The native panel hands back the typed numbers only (no thumbnails were
    // rendered): the placeholder must stay empty and the terminal write must
    // contain the picked items, never every item of the post.
    final batch = batchFor([1, 3, 5]);
    await writePlaceholderHistory(db, batch);
    final placeholder = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(placeholder.files, isEmpty);
    expect(placeholder.fileCount, 0);

    await writeBatchHistory(db, batch, recovered: false);
    final stored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(stored.files.map((f) => f.itemIndex).toList(), [1, 3, 5]);
    expect(stored.savedFiles.length, 3);
  });

  test('an album file the user kept is re-associated when it is downloaded again', () async {    await db.upsert(record([fileRow(1), fileRow(2)]));
    await db.delete((await db.getByPostId('6ae36a66000000002a01e77e'))!.id!);

    // Item 2 was kept in the album, so the downloader reuses that MediaStore
    // entry instead of saving a second copy.
    await writeBatchHistory(
      db,
      DownloadBatch(
        batchId: 'b-kept',
        album: 'EasySave',
        postUrl: 'https://www.xiaohongshu.com/explore/6ae36a66000000002a01e77e',
        platform: 'xhs',
        postId: '6ae36a66000000002a01e77e',
        jobs: [
          DownloadJob(
            key: 'kept-2',
            label: '图片 2',
            filename: 'post_2.jpg',
            urls: ['https://img/2.jpg'],
            isImage: true,
            itemIndex: 2,
          )..state = JobState.done
           ..saved = true
           ..mediaId = 'media-2',
        ],
      ),
      recovered: false,
    );

    final stored = (await db.getByPostId('6ae36a66000000002a01e77e'))!;
    expect(stored.files.length, 1);
    expect(stored.files.single.itemIndex, 2);
    expect(stored.files.single.mediaId, 'media-2');
    expect(stored.files.single.status, FileStatus.found);
  });

  test('the one-time migration drops rows of deleted posts and missing files', () async {
    // A version-6 database still holds the file rows of soft-deleted records and
    // the rows an album scan already reported missing.
    HistoryDb.resetInstanceForTesting();
    final dir = await Directory.systemTemp.createTemp('easysave_migration_');
    final path = '${dir.path}/history_v6.db';
    final legacy = await openDatabase(
      path,
      version: 6,
      onCreate: (raw, _) async {
        await raw.execute(
          'CREATE TABLE history_records('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, platform TEXT NOT NULL,'
          'platform_display_name TEXT, post_id TEXT NOT NULL, author_name TEXT,'
          'title TEXT, caption TEXT, ai_label TEXT, ai_label_source TEXT,'
          'thumbnail_url TEXT, post_url TEXT NOT NULL UNIQUE,'
          'file_count INTEGER NOT NULL, created_at INTEGER NOT NULL,'
          'items_json TEXT, files_json TEXT, is_deleted INTEGER DEFAULT 0,'
          'download_error TEXT)',
        );
      },
    );
    String encode(List<HistoryFile> files) =>
        '[${files.map((f) => '{"filename":"${f.filename}","saved_at":${f.savedAt},'
            '"media_id":${f.mediaId == null ? 'null' : '"${f.mediaId}"'},'
            '"status":"${f.status.name}","item_index":${f.itemIndex},"is_image":1}').join(',')}]';
    await legacy.insert('history_records', {
      'platform': 'xhs',
      'post_id': 'deleted-post',
      'post_url': 'https://www.xiaohongshu.com/explore/deleted-post',
      'file_count': 3,
      'created_at': 1,
      'files_json': encode([fileRow(1), fileRow(2), fileRow(3)]),
      'is_deleted': 1,
    });
    await legacy.insert('history_records', {
      'platform': 'xhs',
      'post_id': 'active-post',
      'post_url': 'https://www.xiaohongshu.com/explore/active-post',
      'file_count': 3,
      'created_at': 2,
      'files_json': encode([
        fileRow(1),
        fileRow(2, status: FileStatus.notFound),
        HistoryFile(
          filename: 'guess.jpg',
          savedAt: 0,
          itemIndex: 3,
          status: FileStatus.unknown,
        ),
      ]),
      'is_deleted': 0,
    });
    await legacy.close();

    HistoryDb.resetInstanceForTesting();
    final migrated = await HistoryDb.instance(dbPath: path);

    final deletedPost = (await migrated.getByPostId('deleted-post'))!;
    expect(deletedPost.isDeleted, isTrue);
    expect(deletedPost.files, isEmpty);

    final activePost = (await migrated.getByPostId('active-post'))!;
    // The row the scan reported missing is gone; the unresolved guess stays as
    // a scan hint (it is never counted) and the confirmed row is untouched.
    expect(activePost.files.map((f) => f.itemIndex).toList(), [1, 3]);
    expect(activePost.savedFiles.length, 1);

    // No album file was touched: the cleanup is a database rewrite only.
    HistoryDb.resetInstanceForTesting();
    final handle = await openDatabase(path);
    await handle.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });
}
