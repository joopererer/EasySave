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
    test('upsert() clears isDeleted flag when merging', () async {
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

      // Rebuild: upsert same record
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

      await db.upsert(rebuild);

      // Should be restored
      final restored = await db.getByPostId('restore1');
      expect(restored, isNotNull);
      expect(restored!.isDeleted, isFalse);
      expect((await db.recent()).length, 1);
    });
  });
}
