import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/history_db.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String path;
  late HistoryDb history;
  late Database raw;
  var sequence = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    final directory = Directory('build/v1410/history-read-efficiency')
      ..createSync(recursive: true);
    path = '${directory.absolute.path}/read_${DateTime.now().microsecondsSinceEpoch}_${sequence++}.db';
    HistoryDb.resetInstanceForTesting();
    history = await HistoryDb.instance(dbPath: path);
    raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
  });
  tearDown(() async {
    await raw.close();
    HistoryDb.resetInstanceForTesting();
    // Retain the synthetic SQLite files in the workspace build directory.
  });

  HistoryRecord record(int index, {bool deleted = false}) => HistoryRecord(
    platform: 'instagram',
    postId: 'ReadCase$index',
    postUrl: 'https://www.instagram.com/p/ReadCase$index/',
    authorName: 'PRIVATE_ACCOUNT_$index',
    title: 'PRIVATE_TITLE_$index',
    caption: 'PRIVATE_CAPTION_$index',
    aiLabel: index.isOdd ? 'AI info' : null,
    aiLabelSource: index.isOdd ? 'platform' : null,
    fileCount: 4,
    createdAt: DateTime.utc(2026, 11, 5).add(Duration(seconds: index ~/ 2)),
    isDeleted: deleted,
    itemsJson: jsonEncode([
      for (var item = 1; item <= 4; item++)
        {
          'type': 'image',
          'url': 'https://scontent.cdninstagram.com/original_${index}_$item.jpg',
          'thumbnailUrl': 'https://scontent.cdninstagram.com/thumb_${index}_$item.jpg',
        },
    ]),
    files: [
      for (var item = 1; item <= 4; item++)
        HistoryFile(
          filename: 'read_${index}_$item.jpg',
          itemIndex: item,
          itemCount: 4,
          savedAt: DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
          mediaId: '${index * 4 + item}',
          assetId: 'synthetic-$index-$item',
          isImage: true,
        ),
    ],
  );

  test('SQLite plans recent and case-folded identity reads with the intended indexes', () async {
    await raw.insert('history_records', record(1).toMap());
    final recentPlan = await raw.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM history_records '
      'WHERE is_deleted = 0 ORDER BY created_at DESC, id DESC LIMIT 10000',
    );
    final identityPlan = await raw.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM history_records '
      'WHERE LOWER(post_id) = LOWER(?) LIMIT 1',
      ['readcase1'],
    );
    final recentDetails = recentPlan.map((row) => row['detail']).join('\n');
    final identityDetails = identityPlan.map((row) => row['detail']).join('\n');
    expect(recentDetails, contains('history_visible_recent'));
    expect(recentDetails.toUpperCase(), isNot(contains('TEMP B-TREE')));
    expect(identityDetails, contains('history_post_id_folded'));
    expect((await history.getByPostId('rEaDcAsE1'))?.postId, 'ReadCase1');
  });

  test('normal identity read finishes while a second WAL connection owns the writer lock', () async {
    await raw.insert('history_records', record(2).toMap());
    final mode = await raw.rawQuery('PRAGMA journal_mode');
    expect(mode.single.values.single.toString().toLowerCase(), 'wal');
    await raw.execute('BEGIN IMMEDIATE');
    var writerReleased = false;
    try {
      await raw.update('history_records', {'caption': 'UNCOMMITTED_CAPTION'},
          where: 'post_id = ?', whereArgs: ['ReadCase2']);
      // This is a deadlock guard for the test, not a device speed threshold.
      // An unnecessary repair write/transaction would wait for the writer;
      // an ordinary WAL snapshot read completes before that lock is released.
      final read = await history.getByPostId('READCASE2')
          .timeout(const Duration(seconds: 10));
      expect(writerReleased, isFalse);
      expect(read?.caption, 'PRIVATE_CAPTION_2');
      expect(read?.files.map((file) => file.itemIndex), [1, 2, 3, 4]);
    } finally {
      await raw.execute('ROLLBACK');
      writerReleased = true;
    }
  });

  test('500-row recent read preserves ordering and JSON and emits aggregate phase metrics', () async {
    final batch = raw.batch();
    for (var i = 0; i < 500; i++) {
      batch.insert('history_records', record(i).toMap());
    }
    batch.insert('history_records', record(999, deleted: true).toMap());
    await batch.commit(noResult: true);
    final lines = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    late List<HistoryRecord> rows;
    try {
      rows = await history.recent(limit: 10000);
    } finally {
      debugPrint = originalPrint;
    }
    expect(rows.map((row) => row.postId), [
      for (var i = 499; i >= 0; i--) 'ReadCase$i',
    ]);
    for (final i in [0, 99, 250, 499]) {
      final row = rows[499 - i];
      expect(row.title, 'PRIVATE_TITLE_$i');
      expect(row.caption, 'PRIVATE_CAPTION_$i');
      expect(row.files.map((file) => file.itemIndex), [1, 2, 3, 4]);
      expect(row.files.last.filename, 'read_${i}_4.jpg');
      expect(row.toPost().items, hasLength(4));
      expect(row.toPost().items.first.thumbnailUrl,
          'https://scontent.cdninstagram.com/thumb_${i}_1.jpg');
      expect(row.aiLabel, i.isOdd ? 'AI info' : null);
      expect(row.aiLabelSource, i.isOdd ? 'platform' : null);
    }
    final timing = lines.singleWhere(
      (line) => line.contains('[HistoryTiming]') && line.contains('step=recent '),
    );
    expect(timing, contains('rows=500'));
    expect(timing, contains('repairCount=0'));
    for (final name in ['queryMs', 'decodeMs', 'repairMs', 'ms']) {
      expect(timing, matches(RegExp('(?: |^)$name=\\d+(?: |\$)')));
    }
    expect(timing, isNot(contains('PRIVATE_')));
    expect(timing, isNot(contains('ReadCase')));
    expect(timing, isNot(contains('https://')));
  });
}
