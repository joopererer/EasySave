// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 57: the home list 「最近保存」 never lists a post that has no
// saved file yet. A placeholder record written while a download starts
// (file_count = 0) used to be rendered there as 「0 个文件」 — the build 56
// regression, where a batch that timed out in `batch-start` (but kept
// downloading) left that placeholder as its only visible record.

import 'dart:io';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch _batch(String postId) => DownloadBatch(
  batchId: 'background-$postId',
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/$postId',
  platform: 'xhs',
  postId: postId,
  title: 'T',
  itemsJson:
      '[{"type":"image","url":"https://img/1.jpg"},{"type":"image","url":"https://img/2.jpg"}]',
  postItemCount: 2,
  jobs: <DownloadJob>[
    for (final i in <int>[1, 2])
      DownloadJob(
        key: 'background-$postId-$i',
        label: '图片 $i',
        filename: 'f$i.jpg',
        urls: <String>['https://img/$i.jpg'],
        isImage: true,
        itemIndex: i,
      ),
  ],
  source: DownloadBatch.sourceBackground,
);

HistoryRecord _savedRecord(String postId) => HistoryRecord(
  platform: 'xhs',
  postId: postId,
  postUrl: 'https://www.xiaohongshu.com/explore/$postId',
  fileCount: 2,
  createdAt: DateTime(2026, 1, 2),
  files: <HistoryFile>[
    HistoryFile(
      filename: 'f1.jpg',
      status: FileStatus.found,
      mediaId: 'media-f1',
      savedAt: DateTime(2026, 1, 2).millisecondsSinceEpoch,
      itemIndex: 1,
      isImage: true,
    ),
    HistoryFile(
      filename: 'f2.jpg',
      status: FileStatus.found,
      mediaId: 'media-f2',
      savedAt: DateTime(2026, 1, 2).millisecondsSinceEpoch,
      itemIndex: 2,
      isImage: true,
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
    final dir = await Directory.systemTemp.createTemp('easysave_recent_test');
    tempDbPath =
        '${dir.path}${Platform.pathSeparator}'
        'recent_${DateTime.now().microsecondsSinceEpoch}.db';
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

  test('a started download is not 「最近保存」 until a file is saved', () async {
    await writePlaceholderHistory(db, _batch('p1'));
    // The history page still shows it, with its progress.
    expect((await db.getByPostId('p1'))!.fileCount, 0);
    // The home list does not: it would read 「0 个文件」.
    expect(recentSavedRecords(await db.recent()), isEmpty);
  });

  test('the terminal write lists the post with its real file count', () async {
    final batch = _batch('p2');
    await writePlaceholderHistory(db, batch);
    for (final job in batch.jobs) {
      job
        ..state = JobState.done
        ..saved = true
        ..savedTitle = job.filename
        ..mediaId = 'media-${job.itemIndex}';
    }
    await writeBatchHistory(db, batch, recovered: false);

    final saved = recentSavedRecords(await db.recent());
    expect(saved.map((r) => r.postId).toList(), equals(<String>['p2']));
    expect(saved.single.fileCount, 2);
  });

  test('a saved post keeps its place next to a running placeholder', () async {
    await db.upsert(_savedRecord('p-saved'));
    await writePlaceholderHistory(db, _batch('p-running'));

    final saved = recentSavedRecords(await db.recent());
    expect(saved.map((r) => r.postId).toList(), equals(<String>['p-saved']));
    expect(saved.single.fileCount, 2);
  });

  test('a failed start with no file writes no visible saved record', () async {
    final batch = _batch('p-failed');
    await writePlaceholderHistory(db, batch);
    for (final job in batch.jobs) {
      job
        ..state = JobState.failed
        ..error = '下载失败';
    }
    await writeBatchHistory(db, batch, recovered: false);

    expect(recentSavedRecords(await db.recent()), isEmpty);
    // The failure stays reachable in the history page.
    final failed = (await db.getByPostId('p-failed'))!;
    expect(failed.fileCount, 0);
    expect(failed.downloadError, isNotNull);
  });
}
