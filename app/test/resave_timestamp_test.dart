import 'dart:io';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  for (final userSave in [true, false]) {
    test('deleted restore userSave=$userSave has correct saved time', () async {
      final dir = await Directory.systemTemp.createTemp('resave_time');
      final db = await HistoryDb.instance(dbPath: '${dir.path}/history.db');
      HistoryRecord row(DateTime at, {bool deleted = false}) => HistoryRecord(
        platform: 'tiktok', postId: '123', postUrl: 'https://www.tiktok.com/@/video/123',
        fileCount: 0, createdAt: at, isDeleted: deleted);
      final old = DateTime(2020), now = DateTime(2026);
      await db.upsert(row(old, deleted: true));
      await db.upsert(row(now), restoreDeleted: true, userSave: userSave);
      final restored = (await db.getByPostId('123'))!;
      expect(restored.isDeleted, isFalse);
      expect(restored.createdAt, userSave ? now : old);
      // The terminal write must not change the start-of-save timestamp again.
      await db.upsert(row(DateTime(2027)), restoreDeleted: true, userSave: userSave);
      expect((await db.getByPostId('123'))!.createdAt, restored.createdAt);
    });
  }
}
