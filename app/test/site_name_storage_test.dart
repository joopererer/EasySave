import 'dart:io';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDown(() {
    SiteRegistry.useBuiltin();
    HistoryDb.resetInstanceForTesting();
  });

  test(
    'v4 database upgrades and backfills names; nameless unknown records stay readable',
    () async {
      final dir = await Directory.systemTemp.createTemp('easysave_site_names_');
      final path = '${dir.path}/history.db';
      final old = await openDatabase(
        path,
        version: 4,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE history_records('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, platform TEXT NOT NULL, post_id TEXT NOT NULL,'
            'author_name TEXT, title TEXT, caption TEXT, ai_label TEXT, ai_label_source TEXT,'
            'thumbnail_url TEXT, post_url TEXT NOT NULL UNIQUE, file_count INTEGER NOT NULL,'
            'created_at INTEGER NOT NULL, items_json TEXT, files_json TEXT, is_deleted INTEGER DEFAULT 0)',
          );
        },
      );
      for (final platform in ['xhs', 'retired']) {
        await old.insert('history_records', {
          'platform': platform,
          'post_id': platform,
          'post_url': 'https://example.test/$platform',
          'file_count': 0,
          'created_at': 0,
        });
      }
      await old.close();
      final db = await HistoryDb.instance(dbPath: path);
      final known = (await db.getByPostId('xhs'))!;
      expect(known.platformDisplayName, '小红书');
      expect((await db.getByPostId('retired'))!.platformDisplayName, isNull);
      SiteRegistry.activate([]);
      // Query again after removal: the backfill really reached SQLite.
      expect((await db.getByPostId('xhs'))!.platformDisplayName, '小红书');
      expect(known.toPost().platformDisplayName, '小红书');
      final handle = await openDatabase(path);
      await handle.close();
      await dir.delete(recursive: true);
    },
  );

  test('record updates after removal retain stored display names', () async {
    SiteRegistry.activate([
      {'id': 'retired', 'platform': 'retired', 'displayName': '保存时名称'},
    ]);
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryRecord record() => HistoryRecord(
      platform: 'retired',
      postId: 'p',
      postUrl: 'https://example.test/p',
      fileCount: 0,
      createdAt: DateTime(2026),
    );
    await db.upsert(record());
    SiteRegistry.activate([]);
    await db.upsert(record());
    expect((await db.getByPostId('p'))!.platformDisplayName, '保存时名称');
  });
}
