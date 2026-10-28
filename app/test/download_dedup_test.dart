import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    await HistoryDb.instance(dbPath: ':memory:');
    manager.prepareStartForTesting = () async =>
        Future<void>.delayed(const Duration(milliseconds: 20));
  });
  tearDown(() async {
    for (final b in await manager.liveBatches()) {
      await DownloadClaims.release(b.batchId);
    }
    manager.prepareStartForTesting = null;
    manager.enqueueForTesting = null;
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });
  ParsedPost post() => ParsedPost(
    platform: 'tiktok',
    id: '123',
    url: 'https://example.invalid',
    author: PostAuthor(),
    items: [MediaItem(type: 'image', url: 'https://example.invalid/a.jpg')],
  );

  test('ten simultaneous saves create and enqueue exactly one batch', () async {
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async {
      enqueued++;
    };
    final results = await Future.wait([
      for (var i = 0; i < 10; i++)
        (() async {
          try {
            return await manager.startBatch(
              post(),
              [0],
              album: 'EasySave',
              nameFor: (_, _, _) => 'same',
            );
          } on AlreadyDownloading {
            return null;
          }
        })(),
    ]);
    expect(results.whereType<DownloadBatch>(), hasLength(1));
    expect(await manager.liveBatches(), hasLength(1));
    expect(enqueued, 1);
  });
  test('preview shows active work ahead of newer failed snapshots', () {
    DownloadBatch b(String id, JobState state, {String platform = 'tiktok'}) =>
        DownloadBatch(
          batchId: id,
          album: 'EasySave',
          postUrl: 'https://example.invalid',
          platform: platform,
          postId: '123',
          jobs: [
            DownloadJob(
              key: id,
              label: '图片',
              filename: 'same.jpg',
              urls: [],
              isImage: true,
              itemIndex: 1,
            )..state = state,
          ],
        );
    final failed = b('old', JobState.failed),
        active = b('active', JobState.active);
    expect(
      previewBatchForPost([failed, active], 'tiktok', '123'),
      same(active),
    );
    expect(
      previewBatchForPost(
        [b('other', JobState.active, platform: 'xhs'), failed],
        'tiktok',
        '123',
      ),
      same(failed),
    );
    expect(
      previewBatchForPost([b('done', JobState.done)], 'tiktok', '123'),
      isNull,
    );
  });
  test('different batches and jobs cannot share a temporary path', () {
    final paths = [
      for (final batch in ['main-1', 'background-2'])
        for (final job in ['a', 'b'])
          '${downloadTempDirectory(batch, job)}/same.jpg',
    ];
    expect(paths.toSet(), hasLength(4));
    expect(
      downloadIdentity('xhs', '123', 1, true),
      isNot(downloadIdentity('tiktok', '123', 1, true)),
    );
    expect(
      downloadIdentity('tiktok', '123', 1, true),
      isNot(downloadIdentity('tiktok', '123', 1, false)),
    );
  });
}
