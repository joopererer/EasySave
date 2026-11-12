import 'dart:convert';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// v1.10.2 build 42: a retry runs as a fresh flow, so the failed batch an older
// attempt left behind (a force-adopted `background-…` batch in the device log)
// kept its failure after a successful retry. The history card and the top of
// the preview page showed the failure strip until the page was rebuilt.
//
// `_afterTerminal` (DownloadBatch finished → history written) drops those
// batches through `forgetSupersededFailuresForTesting`; the fire-and-forget
// backup/notification work that follows it is deliberately out of scope here.

const _postId = '6aeff4780000000010011312';
const _postUrl = 'https://www.xiaohongshu.com/explore/$_postId';

DownloadBatch _batch(
  String id, {
  required bool failed,
  String source = DownloadBatch.sourceMain,
  String postId = _postId,
}) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/$postId',
  platform: 'xhs',
  postId: postId,
  source: source,
  jobs: [
    DownloadJob(
      key: '$id-1',
      label: '图片 1',
      filename: '${postId}_1.heic',
      urls: ['https://ci.xiaohongshu.com/x?imageView2/format/jpg'],
      isImage: true,
      itemIndex: 1,
    )
      ..state = failed ? JobState.failed : JobState.done
      ..error = failed ? '第1项图片保存失败' : null
      ..saved = !failed
      ..mediaId = failed ? null : 'media-$id'
      ..savedTitle = failed ? null : '${postId}_1.heic'
      ..relativePath = failed ? null : 'Pictures/EasySave/',
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  tearDown(() {
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  /// Writes [batch] where the other engine would leave it: as a snapshot.
  Future<void> snapshot(DownloadBatch batch) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'easysave_batch_${batch.batchId}',
      jsonEncode(batch.toJson()),
    );
    final index = prefs.getStringList('easysave_batches') ?? [];
    if (!index.contains(batch.batchId)) index.add(batch.batchId);
    await prefs.setStringList('easysave_batches', index);
  }

  test('a successful retry drops the failed batch it superseded', () async {
    final stale = _batch(
      'background-1700000000000',
      failed: true,
      source: DownloadBatch.sourceBackground,
    );
    await snapshot(stale);
    expect(
      (await manager.liveBatches()).map((b) => b.batchId),
      contains('background-1700000000000'),
      reason: 'this snapshot is what drives the failure strip',
    );

    final retried = _batch('main-1700000001000', failed: false);
    manager.setBatchForTesting(retried);
    await manager.forgetSupersededFailuresForTesting(retried);

    final ids = (await manager.liveBatches()).map((b) => b.batchId).toList();
    expect(ids, isNot(contains('background-1700000000000')),
        reason: 'no page reload may be needed');
    expect(ids, contains('main-1700000001000'));

    // A tombstone keeps the other engine from resurrecting the snapshot.
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('easysave_dismissed_batch_background-1700000000000'),
      isTrue,
    );
  });

  test('an in-memory failed batch is dropped too', () async {
    final stale = _batch('background-memory', failed: true);
    manager.setBatchForTesting(stale);
    final retried = _batch('main-memory', failed: false);
    manager.setBatchForTesting(retried);

    await manager.forgetSupersededFailuresForTesting(retried);

    expect((await manager.liveBatches()).map((b) => b.batchId),
        isNot(contains('background-memory')));
  });

  test('a batch that still has a failure keeps every failure visible', () async {
    final stale = _batch(
      'background-2',
      failed: true,
      source: DownloadBatch.sourceBackground,
    );
    await snapshot(stale);

    final stillFailing = _batch('main-2', failed: true);
    manager.setBatchForTesting(stillFailing);
    await manager.forgetSupersededFailuresForTesting(stillFailing);

    expect((await manager.liveBatches()).map((b) => b.batchId),
        containsAll(<String>['background-2', 'main-2']));
  });

  test('another post keeps its own failure', () async {
    await snapshot(_batch('background-3', failed: true, postId: 'other'));

    final retried = _batch('main-3', failed: false);
    manager.setBatchForTesting(retried);
    await manager.forgetSupersededFailuresForTesting(retried);

    expect((await manager.liveBatches()).map((b) => b.batchId),
        contains('background-3'));
  });

  test('an unfinished batch of the same post is never dropped', () async {
    final running = DownloadBatch(
      batchId: 'background-running',
      album: 'EasySave',
      postUrl: _postUrl,
      platform: 'xhs',
      postId: _postId,
      source: DownloadBatch.sourceBackground,
      jobs: [
        DownloadJob(
          key: 'background-running-1',
          label: '图片 1',
          filename: '${_postId}_2.heic',
          urls: ['https://sns-img-bd.xhscdn.com/a.heic'],
          isImage: true,
          itemIndex: 2,
        )..state = JobState.active,
      ],
    );
    await snapshot(running);

    final retried = _batch('main-4', failed: false);
    manager.setBatchForTesting(retried);
    await manager.forgetSupersededFailuresForTesting(retried);

    expect((await manager.liveBatches()).map((b) => b.batchId),
        contains('background-running'));
  });
}
