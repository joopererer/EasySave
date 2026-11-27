import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/services/history_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<String> createV7Database(Directory dir) async {
    final path = '${dir.path}/v7_history.db';
    final db = await openDatabase(
      path,
      version: 7,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE history_records('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'platform TEXT NOT NULL,'
          'platform_display_name TEXT,'
          'post_id TEXT NOT NULL,'
          'author_name TEXT,'
          'title TEXT,'
          'caption TEXT,'
          'ai_label TEXT,'
          'ai_label_source TEXT,'
          'thumbnail_url TEXT,'
          'post_url TEXT NOT NULL UNIQUE,'
          'file_count INTEGER NOT NULL,'
          'created_at INTEGER NOT NULL,'
          'items_json TEXT,'
          'files_json TEXT,'
          'is_deleted INTEGER DEFAULT 0,'
          'download_error TEXT)',
        );
        await db.insert('history_records', {
          'platform': 'xhs',
          'platform_display_name': '小红书',
          'post_id': 'legacy_post_1',
          'author_name': 'Alice',
          'title': 'Legacy Post',
          'post_url': 'https://www.xiaohongshu.com/explore/legacy_post_1',
          'file_count': 1,
          'created_at': 1700000000000,
          'files_json': jsonEncode([
            {
              'filename': 'legacy_post_1_1.jpg',
              'saved_at': 1700000001000,
              'media_id': '101',
              'status': 'found',
              'item_index': 1,
              'is_image': 1,
              'asset_id': '01960000-0000-7000-8000-000000000101',
              'relative_path': 'Pictures/EasySave/',
            },
          ]),
          'is_deleted': 0,
        });
      },
    );
    await db.close();
    return path;
  }

  test('v7 to v8 migration preserves legacy rows with md5=null and supports new md5 writes', () async {
    final dir = await Directory.systemTemp.createTemp('hist_v8_mig_');
    try {
      final path = await createV7Database(dir);
      HistoryDb.resetInstanceForTesting();
      final hdb = await HistoryDb.instance(dbPath: path);

      final legacy = await hdb.getByPostId('legacy_post_1');
      expect(legacy, isNotNull);
      expect(legacy!.files.length, 1);
      expect(legacy.files.first.md5, isNull);
      expect(legacy.files.first.mediaId, '101');
      expect(legacy.files.first.assetId, '01960000-0000-7000-8000-000000000101');

      // Write a new record with md5
      await hdb.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'new_post_2',
          postUrl: 'https://www.xiaohongshu.com/explore/new_post_2',
          fileCount: 1,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000010000),
          files: [
            HistoryFile(
              filename: 'new_post_2_1.mp4',
              savedAt: 1700000011000,
              mediaId: '202',
              status: FileStatus.found,
              itemIndex: 1,
              isImage: false,
              relativePath: 'Pictures/EasySave/',
              md5: 'd41d8cd98f00b204e9800998ecf8427e',
            ),
          ],
        ),
      );

      final updated = await hdb.getByPostId('new_post_2');
      expect(updated, isNotNull);
      expect(updated!.files.single.md5, 'd41d8cd98f00b204e9800998ecf8427e');
      HistoryDb.resetInstanceForTesting();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('v8 migration is idempotent across repeated opens and survives aborted upgrade', () async {
    final dir = await Directory.systemTemp.createTemp('hist_v8_idem_');
    try {
      final path = await createV7Database(dir);

      // Simulate an aborted upgrade (transaction rolled back, DB still at version 7)
      final rawDb = await openDatabase(path);
      try {
        await rawDb.transaction((txn) async {
          await txn.execute('UPDATE history_records SET title = "Aborted"');
          throw StateError('simulated_kill_mid_upgrade');
        });
      } catch (_) {}
      expect(await rawDb.getVersion(), 7);
      await rawDb.close();

      // Re-open with HistoryDb (upgrades v7 -> v8 cleanly)
      HistoryDb.resetInstanceForTesting();
      final hdb1 = await HistoryDb.instance(dbPath: path);
      final rec1 = await hdb1.getByPostId('legacy_post_1');
      expect(rec1?.title, 'Legacy Post');
      HistoryDb.resetInstanceForTesting();

      // Re-open again (idempotent)
      final hdb2 = await HistoryDb.instance(dbPath: path);
      final rec2 = await hdb2.getByPostId('legacy_post_1');
      expect(rec2?.title, 'Legacy Post');
      expect(rec2?.files.single.mediaId, '101');
      HistoryDb.resetInstanceForTesting();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });
}

