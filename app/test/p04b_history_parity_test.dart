import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/services/transfer_client.dart';
import 'package:easysave/widgets/gallery_browser.dart';

class _FakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];

  @override
  Stream<TransferEvent> get events => controller.stream;

  @override
  Future<String> enqueue({
    String? jobId,
    String direction = 'download',
    String category = 'image',
    String? batchId,
    String? pairId,
    String? fakePlan,
    String? url,
    Map<String, String>? headers,
    String? cookie,
    List<String>? allowedCookieDomains,
    List<Map<String, dynamic>>? policyHosts,
    String? mime,
    String? policyKey,
    Map<String, dynamic>? provenance,
    int? batchTotalCount,
  }) async {
    enqueued.add({'jobId': jobId, 'provenance': provenance});
    return jobId ?? '';
  }

  @override
  Future<bool> ackHistoryWritten(List<String> jobIds) async => true;

  void dispose() {
    unawaited(controller.close());
  }
}

ParsedPost _xVideoPost(String id) {
  return ParsedPost(
    platform: 'x',
    id: id,
    url: 'https://x.com/user/status/$id',
    title: 'Sample X Video',
    author: PostAuthor(name: 'AuthorX', id: 'ax1'),
    items: [
      MediaItem(
        type: 'video',
        url: 'https://video.twimg.com/ext_tw_video/$id/pu/vid/sample.mp4',
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late _FakeTransferClient fakeClient;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04b_parity_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    fakeClient = _FakeTransferClient();

    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = () async {};
    dm.transferClientForTesting = fakeClient;
    dm.tempRootForTesting = () async => tempDir;
    dm.historyWriterForTesting = (db, batch, recovered) async {
      await writeBatchHistory(db, batch, recovered: recovered);
    };
  });

  tearDown(() async {
    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.tempRootForTesting = null;
    dm.historyWriterForTesting = null;
    dm.enqueueForTesting = null;
    fakeClient.dispose();
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('new pipeline HistoryFile matches legacy HistoryFile field-by-field and supports immediate viewer + delete checkbox', () async {
    final dm = DownloadManager.instance;

    // 1. Legacy HistoryFile baseline
    final legacyPost = _xVideoPost('2122697609731260512_legacy');
    final legacyBatch = DownloadBatch(
      batchId: 'legacy-b1',
      album: 'EasySave',
      postUrl: legacyPost.url,
      platform: legacyPost.platform,
      postId: legacyPost.id,
      postItemCount: 1,
      pipeline: DownloadBatch.pipelineLegacy,
      jobs: [],
    );
    final legacyProv = provenanceForBatchItem(legacyBatch, itemIndex: 1);
    legacyBatch.jobs.add(
      DownloadJob(
        key: 'legacy-b1-0',
        itemIndex: 1,
        label: '视频',
        filename: '${legacyPost.id}_1.mp4',
        isImage: false,
        urls: [legacyPost.items.single.url],
      )
        ..state = JobState.done
        ..saved = true
        ..mediaId = '1001'
        ..savedTitle = '2122697609731260512_1.mp4'
        ..relativePath = 'Pictures/EasySave/'
        ..fileBytes = 1048576
        ..md5 = 'abc123'
        ..assetId = legacyProv.assetId
        ..provenanceItemCount = legacyProv.itemCount
        ..provenanceCapturedBy = legacyProv.capturedBy,
    );
    await writeBatchHistory(testDb, legacyBatch, recovered: false);
    final legacyRec = await testDb.getByPostId(legacyPost.id);
    final legacyFile = legacyRec!.files.single;

    // 2. New pipeline DownloadBatch -> TransferCompletedEvent
    dm.useNewTransferPipelineForTesting = true;
    final newPost = _xVideoPost('2122697609731260512_new');
    final newBatch = await dm.startBatch(
      newPost,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${newPost.id}_$s',
    );
    final jobId = newBatch.jobs.single.transferJobId!;

    // Emit StateChanged('done') BEFORE TransferCompletedEvent (matching TransferScheduler order)
    fakeClient.controller.add(
      TransferStateChangeEvent(
        jobId: jobId,
        from: 'finishing',
        to: 'done',
        retryCount: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(newBatch.historyWritten, isFalse);

    fakeClient.controller.add(
      TransferCompletedEvent(
        jobId: jobId,
        mediaId: '2002',
        title: '2122697609731260512_1.mp4',
        relativePath: 'Pictures/EasySave/',
        md5: 'abc123',
        fileSize: 1048576,
      ),
    );
    for (var i = 0; i < 40 && !newBatch.historyWritten; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    final newRec = await testDb.getByPostId(newPost.id);
    expect(newRec, isNotNull);
    final newFile = newRec!.files.single;

    // Field-by-field parity (except mediaId & savedAt; assetId is non-null UUID)
    expect(newFile.filename, legacyFile.filename);
    expect(newFile.status, legacyFile.status);
    expect(newFile.itemIndex, legacyFile.itemIndex);
    expect(newFile.isImage, legacyFile.isImage);
    expect(newFile.relativePath, legacyFile.relativePath);
    expect(newFile.itemCount, legacyFile.itemCount);
    expect(newFile.capturedBy, legacyFile.capturedBy);
    expect(newFile.size, legacyFile.size);
    expect(newFile.notOriginal, legacyFile.notOriginal);
    expect(newFile.pairId, legacyFile.pairId);
    expect(newFile.md5, legacyFile.md5);
    expect(newFile.mediaId, '2002');
    expect(newFile.assetId, isNotNull);
    expect(newFile.assetId, isNotEmpty);

    // Immediate viewer lookup finds the file (no missing placeholder)
    final built = await savedBrowserItems(
      record: newRec,
      files: newRec.visibleFiles,
      post: newPost,
      locate: (file) async => file.mediaId == '2002'
          ? AssetEntity(id: '2002', typeInt: 2, width: 1080, height: 1920)
          : null,
    );
    expect(built.items, hasLength(1));
    expect(built.items.single.missing, isFalse);

    // Delete sheet checkbox condition (canDeleteFiles = itemCount > 0 && summary != '0 项')
    final itemCount = savedItemCountFor([newRec]);
    final counts = deletionCountsForRecords([newRec]);
    expect(itemCount, 1);
    expect(counts.format(nonLiveFallback: '$itemCount 项'), '1 项');
  });

  test('repairIncompleteTransferRows fills only missing fields by mediaId and logs transfer_row_repaired', () async {
    final post = _xVideoPost('2122697609731260512_repair');
    await testDb.upsert(
      HistoryRecord(
        platform: 'x',
        postId: post.id,
        authorName: 'AuthorX',
        title: 'Incomplete',
        postUrl: post.url,
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: '',
            savedAt: 1000,
            mediaId: '3003',
            status: FileStatus.found,
            itemIndex: 1,
            isImage: false,
            relativePath: null,
            size: null,
            md5: 'keep-md5',
          ),
        ],
      ),
      restoreDeleted: true,
    );

    final repaired = await testDb.repairIncompleteTransferRows(
      lookup: (mediaId) async => mediaId == '3003'
          ? (
              filename: '2122697609731260512_1.mp4',
              relativePath: 'Pictures/EasySave/',
              size: 2048,
            )
          : null,
    );
    expect(repaired, 1);

    final after = await testDb.getByPostId(post.id);
    final file = after!.files.single;
    expect(file.filename, '2122697609731260512_1.mp4');
    expect(file.relativePath, 'Pictures/EasySave/');
    expect(file.size, 2048);
    expect(file.md5, 'keep-md5');
    expect(file.savedAt, 1000);
    expect(DevLog.recentLines(100).join('\n'), contains('transfer_row_repaired count=1'));
  });
}
