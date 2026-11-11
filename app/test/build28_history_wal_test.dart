import 'dart:io';

import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'history reads snapshots during continuous writes from another connection',
    () async {
      final directory = Directory('build/build28/wal')
        ..createSync(recursive: true);
      final path =
          '${directory.absolute.path}/concurrent_${DateTime.now().microsecondsSinceEpoch}.db';
      HistoryDb.resetInstanceForTesting();
      final history = await HistoryDb.instance(dbPath: path);
      final writer = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final baseline = HistoryRecord(
        platform: 'xhs',
        postId: 'wal-post',
        postUrl: 'https://example.test/wal-post',
        title: 'Committed',
        fileCount: 0,
        createdAt: DateTime(2026),
      );
      await history.upsert(baseline);
      expect(
        (await writer.rawQuery('PRAGMA journal_mode')).single.values.single,
        'wal',
      );
      var committed = 0;
      try {
        for (var round = 0; round < 12; round++) {
          await writer.execute('BEGIN IMMEDIATE');
          try {
            await writer.update(
              'history_records',
              {'title': 'Round $round'},
              where: 'post_id = ?',
              whereArgs: ['wal-post'],
            );
            final rows = await history.recent().timeout(
              const Duration(seconds: 2),
            );
            expect(
              rows.single.title,
              committed == 0 ? 'Committed' : 'Round ${round - 1}',
            );
            await writer.execute('COMMIT');
            committed++;
          } catch (_) {
            await writer.execute('ROLLBACK');
            rethrow;
          }
        }
        expect((await history.recent()).single.title, 'Round 11');
        expect(committed, 12);
      } finally {
        await writer.close();
        HistoryDb.resetInstanceForTesting();
        // Synthetic databases remain under build/ for diagnosis; no album access.
      }
    },
  );
}
