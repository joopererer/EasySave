import 'dart:io';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch _batch(String postId) => DownloadBatch(
  batchId: 'main-$postId',
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/$postId',
  platform: 'xhs',
  postId: postId,
  title: 'T',
  itemsJson: '[{"type":"image","url":"https://img/1.jpg"}]',
  jobs: [
    DownloadJob(
      key: 'main-$postId-0',
      label: '图片 1',
      filename: 'f1.jpg',
      urls: ['https://img/1.jpg'],
      isImage: true,
      itemIndex: 1,
    ),
  ],
);

void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('easysave_ph_test');
    tempDbPath = p.join(dir.path, 'ph_${DateTime.now().microsecondsSinceEpoch}.db');
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final f = File(tempDbPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  });

  test('placeholder makes the post visible before any file is saved', () async {
    await writePlaceholderHistory(db, _batch('p1'));
    final recent = await db.recent();
    expect(recent, hasLength(1));
    expect(recent.first.postId, 'p1');
    expect(recent.first.files, isEmpty);
    expect(recent.first.fileCount, 0);
  });

  test('placeholder keeps files of an earlier download', () async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'p2',
        postUrl: 'https://www.xiaohongshu.com/explore/p2',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'old.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      ),
    );
    await writePlaceholderHistory(db, _batch('p2'));
    final rec = await db.getByPostId('p2');
    expect(rec!.files, hasLength(1));
    expect(rec.files.first.filename, 'old.jpg');
  });

  test('empty placeholder is discarded when nothing was saved', () async {
    final b = _batch('p3');
    await writePlaceholderHistory(db, b);
    // The terminal write of a failed batch stores itemsJson with no files.
    await writeBatchHistory(db, b, recovered: false);
    await discardEmptyPlaceholder(db, b);
    expect(await db.getByPostId('p3'), isNull);
  });

  test('placeholder with existing files is not discarded', () async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'p4',
        postUrl: 'https://www.xiaohongshu.com/explore/p4',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'old.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            itemIndex: 1,
          ),
        ],
      ),
    );
    final b = _batch('p4');
    await writePlaceholderHistory(db, b);
    await discardEmptyPlaceholder(db, b);
    expect(await db.getByPostId('p4'), isNotNull);
  });
}
