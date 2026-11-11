import 'dart:convert';

import 'package:easysave/pages/download_queue_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/widgets/delete_records_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch selectedBatch({JobState state = JobState.active}) =>
    DownloadBatch(
      batchId: 'selected-four',
      album: 'EasySave',
      platform: 'instagram',
      postId: 'selected-post',
      postUrl: 'https://www.instagram.com/p/selectedPost/',
      title: 'Four selected images',
      postItemCount: 8,
      itemsJson: jsonEncode([
        for (var i = 1; i <= 8; i++)
          {'type': 'image', 'url': 'https://scontent.cdninstagram.com/$i.jpg'},
      ]),
      jobs: [
        for (final index in [2, 4, 6, 8])
          DownloadJob(
            key: 'selected-$index',
            label: '图片 $index',
            filename: 'selected-$index.jpg',
            urls: ['https://scontent.cdninstagram.com/$index.jpg'],
            isImage: true,
            itemIndex: index,
          )..state = state,
      ],
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
    DownloadManager.instance.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
  });
  tearDown(() {
    DownloadManager.instance.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  test(
    'selected four pending jobs do not become eight saved history files',
    () async {
      final batch = selectedBatch();
      await writePlaceholderHistory(db, batch);
      final pending = (await db.getByPostId(batch.postId))!;
      expect(batch.jobs.map((j) => j.itemIndex), [2, 4, 6, 8]);
      expect(pending.files, isEmpty);
      expect(pending.fileCount, 0);
      expect(deletableMediaFor([pending]), isEmpty);
    },
  );

  test(
    'failed terminal write and another placeholder never infer all eight as saved',
    () async {
      final batch = selectedBatch(state: JobState.failed);
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);
      final failed = (await db.getByPostId(batch.postId))!;
      expect(
        failed.files,
        isEmpty,
        reason:
            'An explicitly empty files_json means no album import succeeded.',
      );
      expect(failed.fileCount, 0);
      await writePlaceholderHistory(db, batch);
      final retrying = (await db.getByPostId(batch.postId))!;
      expect(retrying.files, isEmpty);
      expect(retrying.fileCount, 0);
    },
  );

  test(
    'terminal failure keeps only earlier successfully imported items',
    () async {
      final batch = selectedBatch(state: JobState.failed);
      await db.upsert(
        HistoryRecord(
          platform: batch.platform,
          postId: batch.postId,
          postUrl: batch.postUrl,
          fileCount: 1,
          createdAt: DateTime(2026),
          itemsJson: batch.itemsJson,
          files: [
            HistoryFile(
              filename: 'earlier.jpg',
              savedAt: 1,
              itemIndex: 3,
              status: FileStatus.found,
              mediaId: 'verified-3',
            ),
          ],
        ),
      );
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);
      final merged = (await db.getByPostId(batch.postId))!;
      expect(merged.files.map((f) => f.itemIndex), [3]);
      expect(merged.fileCount, 1);
      expect(deletableMediaFor([merged]).map((m) => m.mediaId), ['verified-3']);
    },
  );

  test(
    'retry placeholder does not promote eight inferred candidates into saved rows',
    () async {
      final batch = selectedBatch(state: JobState.failed);
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);
      await writePlaceholderHistory(db, batch);
      final retrying = (await db.getByPostId(batch.postId))!;
      expect(retrying.fileCount, 0);
      expect(retrying.files, isEmpty);
    },
  );

  test(
    'explicit empty file list is authoritative while absent legacy list may be inferred',
    () {
      final batch = selectedBatch(state: JobState.failed);
      final map = HistoryRecord(
        platform: batch.platform,
        postId: batch.postId,
        postUrl: batch.postUrl,
        fileCount: 0,
        createdAt: DateTime(2026),
        itemsJson: batch.itemsJson,
        files: const [],
      ).toMap();
      expect(HistoryRecord.fromMap(map).files, isEmpty);
      map['files_json'] = null;
      expect(
        HistoryRecord.fromMap(map).files,
        hasLength(8),
        reason:
            'Legacy records without any explicit list keep their existing reconstruction path.',
      );
    },
  );

  test(
    'partial import records only saved selected jobs, preserving original indices',
    () async {
      final batch = selectedBatch(state: JobState.failed);
      batch.jobs.first
        ..state = JobState.done
        ..saved = true
        ..mediaId = 'verified-2';
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostId(batch.postId))!;
      expect(record.files.map((f) => f.itemIndex), [2]);
      expect(record.fileCount, 1);
      expect(deletableMediaFor([record]).map((m) => m.mediaId), ['verified-2']);
    },
  );

  testWidgets('queue shows only selected jobs while downloading', (
    tester,
  ) async {
    final batch = selectedBatch();
    DownloadManager.instance.setBatchForTesting(batch);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: DownloadQueuePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('下载中 · 0/4 个文件'), findsOneWidget);
    await tester.tap(find.text('Four selected images'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (var index = 1; index <= 8; index++) {
      expect(
        find.text('第 $index 项'),
        index.isEven ? findsOneWidget : findsNothing,
      );
    }
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('all four failed selected jobs remain visible with retry actions', (
    tester,
  ) async {
    final batch = selectedBatch(state: JobState.failed);
    DownloadManager.instance.setBatchForTesting(batch);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: DownloadQueuePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Four selected images'),
      findsOneWidget,
      reason:
          'Failed terminal work must remain actionable, not look saved or disappear.',
    );
    await tester.tap(find.text('Four selected images'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('重试失败项'), findsOneWidget);
    expect(find.byTooltip('重试此文件'), findsNWidgets(4));
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets(
    'delete sheet counts located album files, not eight remote candidates',
    (tester) async {
      final batch = selectedBatch(state: JobState.failed);
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host = context;
              return const Scaffold();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        await writePlaceholderHistory(db, batch);
        await writeBatchHistory(db, batch, recovered: false);
      });
      final record = await tester.runAsync(() => db.getByPostId(batch.postId));
      final future = showDeleteRecordsSheet(
        host,
        recordCount: 1,
        fileCount: deletableMediaFor([record!]).length,
        cancelDownloads: true,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('同时删除相册中的'), findsNothing);
      expect(find.text('同时取消正在进行的下载'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await future, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
