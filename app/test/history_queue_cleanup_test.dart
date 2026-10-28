import 'dart:convert';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_deletion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DownloadBatch batch(
  String id,
  List<JobState> states, {
  String post = 'post',
  String source = 'main',
}) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: 'https://example.invalid/$post',
  platform: 'xhs',
  postId: post,
  source: source,
  jobs: [
    for (var i = 0; i < states.length; i++)
      DownloadJob(
          key: '$id-$i',
          label: '图片',
          filename: '$i.jpg',
          urls: ['https://example.invalid/a.jpg'],
          isImage: true,
          itemIndex: i + 1,
        )
        ..state = states[i]
        ..error = states[i] == JobState.failed ? '下载失败' : null,
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late HistoryDb db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager.clearBatchesForTesting();
    manager.onBatchSuccess.value = null;
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
  });
  tearDown(() {
    manager.clearBatchesForTesting();
    manager.onBatchSuccess.value = null;
    HistoryDb.resetInstanceForTesting();
  });

  Future<void> snapshot(DownloadBatch b) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'easysave_batch_${b.batchId}',
      jsonEncode(b.toJson()),
    );
    final index = prefs.getStringList('easysave_batches') ?? [];
    if (!index.contains(b.batchId)) index.add(b.batchId);
    await prefs.setStringList('easysave_batches', index);
  }

  test(
    'history deletion clears terminal batches, snapshots and success hint while retaining active work',
    () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post',
          postUrl: 'https://example.invalid/post',
          fileCount: 1,
          createdAt: DateTime.now(),
        ),
      );
      final record = (await db.getByPostId('post'))!;
      final done = batch('done', [JobState.done]);
      final batches = [
        done,
        batch('failed', [JobState.failed, JobState.failed]),
        batch('mixed', [JobState.done, JobState.failed]),
        batch('canceled', [JobState.canceled]),
        batch('active', [JobState.active, JobState.failed]),
        batch('queued', [JobState.queued]),
        batch('paused', [JobState.paused]),
        batch('other', [JobState.failed], post: 'other'),
      ];
      for (final b in batches) {
        manager.setBatchForTesting(b);
        await snapshot(b);
      }
      manager.onBatchSuccess.value = done;
      await deleteHistoryRecords(db, [record]);
      expect(await db.recent(), isEmpty);
      expect(manager.onBatchSuccess.value, isNull);
      final remaining = await manager.liveBatches();
      expect(remaining.map((b) => b.batchId).toSet(), {
        'active',
        'queued',
        'paused',
        'other',
      });
      expect(manager.batchById('active')!.jobs.first.state, JobState.active);
      final prefs = await SharedPreferences.getInstance();
      for (final id in ['done', 'failed', 'mixed', 'canceled']) {
        expect(prefs.containsKey('easysave_batch_$id'), isFalse);
        expect(prefs.getStringList('easysave_batches'), isNot(contains(id)));
      }
    },
  );

  test(
    'foreign terminal snapshots are cleared without adopting or cancelling foreign active work',
    () async {
      final failed = batch('foreign-failed', [
        JobState.failed,
      ], source: 'background');
      final active = batch('foreign-active', [
        JobState.active,
      ], source: 'background');
      await snapshot(failed);
      await snapshot(active);
      await manager.clearTerminalBatchesForPost('post');
      expect((await manager.liveBatches()).map((b) => b.batchId), [
        'foreign-active',
      ]);
      expect(manager.batchById('foreign-active'), isNull);
      expect((await manager.activeBatchForPost('post'))!.source, 'background');
    },
  );

  test(
    'stale engine memory cannot restore the old failure strip after deletion or undo',
    () async {
      final failed = batch('old', [JobState.failed]);
      manager.setBatchForTesting(failed);
      await snapshot(failed);
      await manager.clearTerminalBatchesForPost('post');
      manager.setBatchForTesting(failed); // stale memory in another engine
      await snapshot(failed); // stale disk snapshot from that engine
      expect(await manager.liveBatches(), isEmpty);
      expect(manager.currentBatch, isNull);
      final fresh = batch('new', [JobState.active]);
      manager.setBatchForTesting(fresh);
      expect((await manager.liveBatches()).single.batchId, 'new');
    },
  );
}
