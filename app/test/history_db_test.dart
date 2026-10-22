// Copyright 2026 EasySave. All rights reserved.
// Tests for HistoryDb soft delete and rebuild behavior.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/services/history_db.dart';

void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_test');
    tempDbPath = p.join(tempDir.path, 'test_history_${DateTime.now().millisecondsSinceEpoch}.db');
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  });

  group('Soft delete', () {
    test('delete() marks record as deleted without removing it', () async {
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'test123',
        postUrl: 'https://example.com/test123',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'test.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );

      await db.upsert(record);
      final inserted = await db.getByPostId('test123');
      expect(inserted, isNotNull);
      expect(inserted!.isDeleted, isFalse);

      // Soft delete
      await db.delete(inserted.id!);

      // Record still exists but marked as deleted
      final deleted = await db.getByPostId('test123');
      expect(deleted, isNotNull);
      expect(deleted!.isDeleted, isTrue);
    });

    test('recent() excludes deleted records', () async {
      final record1 = HistoryRecord(
        platform: 'xhs',
        postId: 'keep1',
        postUrl: 'https://example.com/keep1',
        fileCount: 1,
        createdAt: DateTime.now(),
      );
      final record2 = HistoryRecord(
        platform: 'xhs',
        postId: 'delete2',
        postUrl: 'https://example.com/delete2',
        fileCount: 1,
        createdAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      await db.upsert(record1);
      await db.upsert(record2);

      expect((await db.recent()).length, 2);

      final toDelete = await db.getByPostId('delete2');
      await db.delete(toDelete!.id!);

      final remaining = await db.recent();
      expect(remaining.length, 1);
      expect(remaining.first.postId, 'keep1');
    });
  });

  group('Rebuild restores deleted records', () {
    test('upsert() with restoreDeleted=true clears isDeleted flag', () async {
      final original = HistoryRecord(
        platform: 'xhs',
        postId: 'restore1',
        postUrl: 'https://example.com/restore1',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      );

      await db.upsert(original);
      final inserted = await db.getByPostId('restore1');
      await db.delete(inserted!.id!);

      // Verify it's deleted
      final deleted = await db.getByPostId('restore1');
      expect(deleted!.isDeleted, isTrue);
      expect((await db.recent()).isEmpty, isTrue);

      // Rebuild: upsert same record with restoreDeleted=true
      final rebuild = HistoryRecord(
        platform: 'xhs',
        postId: 'restore1',
        postUrl: 'https://example.com/restore1',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      );

      await db.upsert(rebuild, restoreDeleted: true);

      // Should be restored
      final restored = await db.getByPostId('restore1');
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });

    test('upsert() without restoreDeleted preserves deleted state', () async {
      final original = HistoryRecord(
        platform: 'xhs',
        postId: 'stay_deleted',
        postUrl: 'https://example.com/stay_deleted',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      );

      await db.upsert(original);
      final inserted = await db.getByPostId('stay_deleted');
      await db.delete(inserted!.id!);

      // Regular upsert (e.g., from download or status update)
      final update = HistoryRecord(
        platform: 'xhs',
        postId: 'stay_deleted',
        postUrl: 'https://example.com/stay_deleted',
        fileCount: 2,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
          HistoryFile(
            filename: 'file2.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 2,
          ),
        ],
      );

      await db.upsert(update);

      // Should still be deleted
      final stillDeleted = await db.getByPostId('stay_deleted');
      expect(stillDeleted, isNotNull);
      expect(stillDeleted!.isDeleted, isTrue);
      expect(stillDeleted.files.length, 2); // Files were merged
      expect((await db.recent()).isEmpty, isTrue);
    });

    test('user re-download of deleted post restores it', () async {
      final original = HistoryRecord(
        platform: 'xhs',
        postId: 'redownload',
        postUrl: 'https://example.com/redownload',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      );

      await db.upsert(original);
      final inserted = await db.getByPostId('redownload');
      await db.delete(inserted!.id!);

      // User initiates a new download (live update, not recovered batch)
      final redownload = HistoryRecord(
        platform: 'xhs',
        postId: 'redownload',
        postUrl: 'https://example.com/redownload',
        fileCount: 2,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
          HistoryFile(
            filename: 'file2.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 2,
          ),
        ],
      );

      await db.upsert(redownload, restoreDeleted: true);

      // Should be restored
      final restored = await db.getByPostId('redownload');
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect(restored.files.length, 2);
      expect((await db.recent()).length, 1);
    });

    test('startup reconcile does not restore stopped download', () async {
      final original = HistoryRecord(
        platform: 'xhs',
        postId: 'no_restore',
        postUrl: 'https://example.com/no_restore',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      );

      await db.upsert(original);
      final inserted = await db.getByPostId('no_restore');
      await db.delete(inserted!.id!);

      // Simulates a reconcile without user action (e.g., updating file status)
      final update = HistoryRecord(
        platform: 'xhs',
        postId: 'no_restore',
        postUrl: 'https://example.com/no_restore',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'file1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
            status: FileStatus.found,
          ),
        ],
      );

      // Reconcile: recovered=true but we're NOT restoring
      await db.upsert(update, restoreDeleted: false);

      // Should still be deleted
      final stillDeleted = await db.getByPostId('no_restore');
      expect(stillDeleted, isNotNull);
      expect(stillDeleted!.isDeleted, isTrue);
      expect((await db.recent()).isEmpty, isTrue);
    });

    test('Task 3: reinsert clears is_deleted flag', () async {
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'reinsert_test',
        postUrl: 'https://example.com/reinsert_test',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'test.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );

      // Insert and soft-delete
      await db.upsert(record);
      final inserted = await db.getByPostId('reinsert_test');
      await db.delete(inserted!.id!);

      // Verify it's deleted
      var deleted = await db.getByPostId('reinsert_test');
      expect(deleted!.isDeleted, isTrue);
      expect((await db.recent()).isEmpty, isTrue);

      // Undo: reinsert must clear the deleted flag
      await db.reinsert(deleted);

      // Should be restored and visible
      final restored = await db.getByPostId('reinsert_test');
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });

    test('Task 3: delete/clear/reinsert notify listeners', () async {
      var notifyCount = 0;
      db.addListener(() => notifyCount++);

      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'listen_test',
        postUrl: 'https://example.com/listen_test',
        fileCount: 1,
        createdAt: DateTime.now(),
      );

      // upsert notifies
      await db.upsert(record);
      expect(notifyCount, 1);

      // delete notifies
      final inserted = await db.getByPostId('listen_test');
      await db.delete(inserted!.id!);
      expect(notifyCount, 2);

      // reinsert notifies
      await db.reinsert(inserted);
      expect(notifyCount, 3);

      // clear notifies
      await db.clear();
      expect(notifyCount, 4);
    });
  });

  // ---------------------------------------------------------------------
  // Task 3 fix (v1.7): every way of deleting from the history page must
  // reach a listener. The page itself never notifies — it only calls the
  // HistoryDb methods exercised below — so these are the paths that matter:
  //   swipe to delete  -> _deleteRecords([record])   -> delete(id) per row
  //   multi select     -> _deleteRecords(records)    -> delete(id) per row
  //   delete with files-> MediaDeleteService + the same delete(id) loop
  //   clear all        -> db.clear()
  // ---------------------------------------------------------------------
  group('Every delete path notifies listeners', () {
    Future<HistoryRecord> addRecord(String postId) async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: postId,
          postUrl: 'https://example.com/$postId',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [HistoryFile(filename: '$postId.jpg', savedAt: 0)],
        ),
      );
      return (await db.getByPostId(postId))!;
    }

    test('swipe delete (single record) notifies', () async {
      var notified = 0;
      db.addListener(() => notified++);

      final record = await addRecord('swipe_1');
      notified = 0;

      await db.delete(record.id!);

      expect(notified, 1);
      expect(await db.recent(), isEmpty);
    });

    test('multi-select delete notifies once per record and empties the list',
        () async {
      final records = [
        await addRecord('multi_1'),
        await addRecord('multi_2'),
        await addRecord('multi_3'),
      ];

      var notified = 0;
      db.addListener(() => notified++);

      for (final record in records) {
        await db.delete(record.id!);
      }

      expect(notified, records.length);
      expect(await db.recent(), isEmpty);
    });

    test('delete with album files still notifies', () async {
      final record = await addRecord('with_files');
      var notified = 0;
      db.addListener(() => notified++);

      // MediaDeleteService runs before the record deletion; the record write
      // is the same call as the plain delete path.
      await db.delete(record.id!);

      expect(notified, 1);
      expect(await db.recent(), isEmpty);
    });

    test('clear all notifies', () async {
      await addRecord('clear_1');
      await addRecord('clear_2');
      var notified = 0;
      db.addListener(() => notified++);

      await db.clear();

      expect(notified, 1);
      expect(await db.recent(), isEmpty);
    });

    test('permanentlyDelete notifies', () async {
      final record = await addRecord('perm_1');
      var notified = 0;
      db.addListener(() => notified++);

      await db.permanentlyDelete(record.id!);

      expect(notified, 1);
      expect(await db.getByPostId('perm_1'), isNull);
    });

    test('updateFiles notifies (status refresh path)', () async {
      final record = await addRecord('status_1');
      var notified = 0;
      db.addListener(() => notified++);

      await db.updateFiles(record.id!, [
        HistoryFile(filename: 'status_1.jpg', savedAt: 0, status: FileStatus.found),
      ]);

      expect(notified, 1);
    });

    test('a throwing listener does not block the others', () async {
      final record = await addRecord('isolated');
      var reached = 0;
      db.addListener(() => throw StateError('boom'));
      db.addListener(() => reached++);

      await db.delete(record.id!);

      expect(reached, 1);
    });
  });

  // ---------------------------------------------------------------------
  // Task 3 listener fix (v1.7): the listener list lives on the HistoryDb
  // instance, so the app must only ever get one. instance() used to cache the
  // finished object rather than the in-flight future; two callers starting
  // while openDatabase() was still running each got their own handle, and the
  // page's listener ended up on the handle nobody wrote through ("notify …
  // but no listeners attached").
  // ---------------------------------------------------------------------
  group('HistoryDb is one shared store', () {
    late String sharedDbPath;

    setUp(() async {
      HistoryDb.resetInstanceForTesting();
      final tempDir = await Directory.systemTemp.createTemp('easysave_shared');
      sharedDbPath =
          '${tempDir.path}/shared_${DateTime.now().microsecondsSinceEpoch}.db';
    });

    tearDown(() async {
      HistoryDb.resetInstanceForTesting();
      try {
        final file = File(sharedDbPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Ignore cleanup errors
      }
    });

    test('concurrent instance() calls return the same object', () async {
      // Both calls are issued before the first open finishes — this is what
      // startup does (main() init, ParsePage attach, gallery locator).
      final first = HistoryDb.instance(dbPath: sharedDbPath);
      final second = HistoryDb.instance(dbPath: sharedDbPath);
      final a = await first;
      final b = await second;

      expect(
        identical(a, b),
        isTrue,
        reason: 'a second handle would carry its own, empty listener list',
      );
    });

    test('history page delete notifies the home page listener', () async {
      final home = await HistoryDb.instance(dbPath: sharedDbPath);
      var refreshed = 0;
      home.addListener(() => refreshed++);

      await home.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'shared_store',
          postUrl: 'https://example.com/shared_store',
          fileCount: 1,
          createdAt: DateTime.now(),
        ),
      );
      refreshed = 0;

      // The history page resolves its own handle and deletes through it.
      final historyPage = await HistoryDb.instance(dbPath: sharedDbPath);
      final record = await historyPage.getByPostId('shared_store');
      await historyPage.delete(record!.id!);

      expect(refreshed, 1);
      expect(await home.recent(), isEmpty);
    });

    test('adding the same listener twice notifies it once', () async {
      final store = await HistoryDb.instance(dbPath: sharedDbPath);
      var calls = 0;
      void listener() => calls++;
      store.addListener(listener);
      store.addListener(listener);

      await store.clear();

      expect(calls, 1);
    });
  });
}
