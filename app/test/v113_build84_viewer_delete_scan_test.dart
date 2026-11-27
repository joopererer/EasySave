// Copyright 2026 EasySave. All rights reserved.
// v1.13 build 84: Viewer batch delete with concurrent gallery scan protection.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_item_delete.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _testPostId = '6b014422testpost';

HistoryFile _row(
  int index, {
  FileStatus status = FileStatus.found,
  String? mediaId,
  bool image = true,
}) =>
    HistoryFile(
      filename: '${_testPostId}_$index.${image ? 'jpg' : 'mp4'}',
      savedAt: 1000,
      mediaId: mediaId ?? '${index}0${image ? 1 : 2}',
      status: status,
      itemIndex: index,
      isImage: image,
      pairId: '$_testPostId#$index',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  });

  tearDown(() => HistoryDb.resetInstanceForTesting());

  test('Batch delete 8 items from 10-item post with 2 Live photos while gallery scan runs concurrently', () async {
    // 10 items, 12 files: item 1 & 2 are Live (4 files), items 3..10 are regular images (8 files)
    final files = <HistoryFile>[
      _row(1, image: true, mediaId: 'm1_img'),
      _row(1, image: false, mediaId: 'm1_vid'),
      _row(2, image: true, mediaId: 'm2_img'),
      _row(2, image: false, mediaId: 'm2_vid'),
      for (int i = 3; i <= 10; i++)
        _row(i, image: true, mediaId: 'm${i}_img'),
    ];

    expect(files.length, 12);
    expect(pairSavedMedia(files).length, 10);

    final record = HistoryRecord(
      platform: 'xhs',
      postId: _testPostId,
      postUrl: 'https://www.xiaohongshu.com/explore/$_testPostId',
      title: 'Live Photo 10 Items Post',
      fileCount: 12,
      createdAt: DateTime.now(),
      itemsJson: jsonEncode([
        {'type': 'live_photo'},
        {'type': 'live_photo'},
        for (int i = 3; i <= 10; i++) {'type': 'image'},
      ]),
      files: files,
    );

    await db.upsert(record);
    final stored = (await db.getByPostId(_testPostId))!;
    final recordId = stored.id!;
    expect(stored.files.length, 12);
    expect(savedMediaEntryCount(stored.savedFiles), 10);

    // Snapshot before scan
    final beforeScan = List<HistoryFile>.from(stored.files);
    // Scanned result where deleted album assets return notFound
    final scannedResult = [
      for (final f in beforeScan)
        f.itemIndex <= 8 ? f.copyWith(status: FileStatus.notFound) : f,
    ];

    // Delete 8 items (indices 0..7, corresponding to itemIndex 1..8):
    // indices 0 & 1 are Live (4 files), indices 2..7 are images (6 files). Total 10 files.
    // In deleteMedia mock, simulate a concurrent gallery scan running during deletion.
    final selectedIndices = {0, 1, 2, 3, 4, 5, 6, 7};
    Future<List<HistoryFile>>? scanFuture;

    final outcome = await deleteHistoryItems(
      stored,
      itemIndices: selectedIndices,
      deleteAlbumFiles: true,
      database: db,
      deleteMedia: (refs) async {
        // Concurrently insert an external gallery-scan call for the same post!
        scanFuture = Zone.root.run(
          () => db.syncScannedFiles(recordId, beforeScan, scannedResult),
        );
        return MediaDeleteOutcome(
          approved: true,
          requested: refs.length,
          remaining: 0,
        );
      },
    );

    expect(outcome.ok, isTrue);
    if (scanFuture != null) {
      await scanFuture;
    }

    // Verify database state after both deletion and scan finish
    final refreshed = (await db.getByPostId(_testPostId))!;

    // 1. Remaining visible items is exactly 2
    final visibleEntries = pairSavedMedia(refreshed.visibleFiles);
    expect(visibleEntries.length, 2);

    // 2. No broken placeholders in visible files
    expect(refreshed.visibleFiles.length, 2);
    expect(refreshed.visibleFiles.every((f) => f.status == FileStatus.found), isTrue);

    // 3. Missing count is 0 (no "补下缺失")
    expect(refreshed.missingFiles.length, 0);

    // 4. Card count is 2
    expect(savedMediaEntryCount(refreshed.savedFiles), 2);
  });

  test('Control: Batch delete 5 items from 7-item non-Live post with concurrent scan', () async {
    const ctrlPostId = 'ctrl_post_no_live';
    final files = <HistoryFile>[
      for (int i = 1; i <= 7; i++)
        _row(i, image: true, mediaId: 'ctrl_${i}_img'),
    ];

    final record = HistoryRecord(
      platform: 'xhs',
      postId: ctrlPostId,
      postUrl: 'https://www.xiaohongshu.com/explore/$ctrlPostId',
      title: 'Control Post',
      fileCount: 7,
      createdAt: DateTime.now(),
      itemsJson: jsonEncode([for (int i = 1; i <= 7; i++) {'type': 'image'}]),
      files: files,
    );

    await db.upsert(record);
    final stored = (await db.getByPostId(ctrlPostId))!;
    final recordId = stored.id!;

    final beforeScan = List<HistoryFile>.from(stored.files);
    final scannedResult = [
      for (final f in beforeScan)
        f.itemIndex <= 5 ? f.copyWith(status: FileStatus.notFound) : f,
    ];

    Future<List<HistoryFile>>? scanFuture;

    final outcome = await deleteHistoryItems(
      stored,
      itemIndices: {0, 1, 2, 3, 4},
      deleteAlbumFiles: true,
      database: db,
      deleteMedia: (refs) async {
        scanFuture = Zone.root.run(
          () => db.syncScannedFiles(recordId, beforeScan, scannedResult),
        );
        return MediaDeleteOutcome(
          approved: true,
          requested: refs.length,
          remaining: 0,
        );
      },
    );

    expect(outcome.ok, isTrue);
    if (scanFuture != null) {
      await scanFuture;
    }

    final refreshed = (await db.getByPostId(ctrlPostId))!;
    expect(refreshed.visibleFiles.length, 2);
    expect(refreshed.missingFiles.length, 0);
    expect(savedMediaEntryCount(refreshed.savedFiles), 2);
  });

  test('Broken placeholder recovery: Delete already broken notFound placeholders clears them permanently', () async {
    const brokenPostId = 'broken_record_repair';
    // Record in broken state: 8 items are notFound (broken placeholders), 2 items are found
    final brokenFiles = <HistoryFile>[
      _row(1, image: true, status: FileStatus.notFound),
      _row(1, image: false, status: FileStatus.notFound),
      _row(2, image: true, status: FileStatus.notFound),
      _row(2, image: false, status: FileStatus.notFound),
      for (int i = 3; i <= 8; i++)
        _row(i, image: true, status: FileStatus.notFound),
      _row(9, image: true, status: FileStatus.found),
      _row(10, image: true, status: FileStatus.found),
    ];

    final record = HistoryRecord(
      platform: 'xhs',
      postId: brokenPostId,
      postUrl: 'https://www.xiaohongshu.com/explore/$brokenPostId',
      title: 'Broken Record',
      fileCount: 2,
      createdAt: DateTime.now(),
      itemsJson: jsonEncode([
        {'type': 'live_photo'},
        {'type': 'live_photo'},
        for (int i = 3; i <= 10; i++) {'type': 'image'},
      ]),
      files: brokenFiles,
    );

    await db.upsert(record);
    final stored = (await db.getByPostId(brokenPostId))!;
    final recordId = stored.id!;

    // Initial broken state has 8 missing items (10 files = 8 items)
    expect(stored.missingFiles.length, 10);

    // Delete the 8 broken items in the viewer (indices 0..7)
    final outcome = await deleteHistoryItems(
      stored,
      itemIndices: {0, 1, 2, 3, 4, 5, 6, 7},
      deleteAlbumFiles: true,
      database: db,
    );

    expect(outcome.ok, isTrue);

    // Now run gallery-scan on this record
    final afterDel = (await db.getByPostId(brokenPostId))!;
    final beforeScan = List<HistoryFile>.from(afterDel.files);
    final scanResult = List<HistoryFile>.from(afterDel.files);
    await db.syncScannedFiles(recordId, beforeScan, scanResult);

    // Verify: placeholders are now permanently deleted, not resurrected
    final refreshed = (await db.getByPostId(brokenPostId))!;
    expect(refreshed.visibleFiles.length, 2);
    expect(refreshed.missingFiles.length, 0);
    expect(savedMediaEntryCount(refreshed.savedFiles), 2);
  });
}
